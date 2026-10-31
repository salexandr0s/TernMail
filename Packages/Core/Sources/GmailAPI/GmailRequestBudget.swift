import Foundation

/// One account's Gmail traffic shares this budget, including mail sync,
/// attachments and settings. Calendar and People requests use their own APIs.
public actor GmailRequestBudget {
    /// 4,000 units per minute plus a 500-unit burst leaves room below the
    /// 6,000-unit per-user quota used by new Google Cloud projects.
    public static let maximumRequestUnits = 500
    /// A full thread read can start even while background work uses the budget.
    static let interactiveReserve = 120
    static var maximumBatchUnits: Int {
        priority == .interactive ? maximumRequestUnits : maximumRequestUnits - interactiveReserve
    }

    public enum Priority: Sendable, Hashable { case background, interactive }
    /// Inherited by requests made while opening a message. Unclassified work
    /// stays in the background lane, including sync and speculative downloads.
    @TaskLocal public static var priority: Priority = .background
    private let unitsPerSecond: Double
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private var availableUnits: Double = Double(maximumRequestUnits)
    private var updatedAt: TimeInterval
    private var blockedUntil: TimeInterval = 0
    private var executing: Set<Priority> = []
    private var waiters: [Waiter] = []
    private var wake: Task<Void, Never>?
    private var wakeGeneration = 0
    private var wakeDeadline: TimeInterval?

    private struct Waiter {
        let id: UUID
        let units: Int
        let priority: Priority
        let continuation: CheckedContinuation<Void, any Error>
    }

    public init(
        unitsPerMinute: Double = 4_000,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        precondition(unitsPerMinute.isFinite && unitsPerMinute > 0)
        unitsPerSecond = unitsPerMinute / 60
        self.now = now
        self.sleep = sleep
        updatedAt = now()
    }

    /// Queued cancellation removes the waiter without consuming quota. Once
    /// admitted, the reservation remains charged even if the request fails.
    func perform<Value: Sendable>(
        units: Int, _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let priority = Self.priority
        let limit = priority == .interactive ? Self.maximumRequestUnits : Self.maximumRequestUnits - Self.interactiveReserve
        guard units > 0, units <= limit else {
            throw GmailError.invalidRequest("Gmail request exceeds its quota budget")
        }
        try await acquire(units: units, priority: priority)
        defer {
            executing.remove(priority)
            schedule()
        }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Retry-After applies to every Gmail caller sharing this account.
    func postpone(for seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        blockedUntil = max(blockedUntil, now() + seconds)
        schedule()
    }

    private func acquire(units: Int, priority: Priority) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, units: units, priority: priority, continuation: continuation))
                schedule()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        schedule()
    }

    private func schedule() {
        let instant = max(updatedAt, now())
        availableUnits = min(Double(Self.maximumRequestUnits), availableUnits + (instant - updatedAt) * unitsPerSecond)
        updatedAt = instant
        while let index = nextWaiterIndex() {
            let first = waiters[index]
            let reserve = first.priority == .background ? Self.interactiveReserve : 0
            let delay = max(blockedUntil - instant, (Double(first.units + reserve) - availableUnits) / unitsPerSecond)
            if delay > 0 {
                scheduleWake(at: instant + delay, delay: delay)
                return
            }
            cancelWake()
            availableUnits -= Double(first.units)
            executing.insert(first.priority)
            waiters.remove(at: index).continuation.resume()
        }
        cancelWake()
    }

    private func nextWaiterIndex() -> Int? {
        // One request per lane prevents slow background HTTP from occupying
        // the reader's slot. FIFO is preserved within each lane.
        if !executing.contains(.interactive),
           let index = waiters.firstIndex(where: { $0.priority == .interactive }) { return index }
        guard !executing.contains(.background) else { return nil }
        return waiters.firstIndex(where: { $0.priority == .background })
    }

    private func cancelWake() {
        guard wake != nil else { return }
        wakeGeneration += 1
        wake?.cancel()
        wake = nil
        wakeDeadline = nil
    }

    private func scheduleWake(at deadline: TimeInterval, delay: TimeInterval) {
        // An interactive arrival may need only 120 units while a background
        // batch is waiting for 500. Replace that timer instead of inheriting it.
        if let wakeDeadline, wakeDeadline <= deadline { return }
        cancelWake()
        wakeGeneration += 1
        let generation = wakeGeneration
        let interval = min(max(delay, 0.001), 60)
        wakeDeadline = updatedAt + interval
        wake = Task { [sleep] in
            do {
                try await sleep(.seconds(interval))
                finishWait(generation: generation, error: nil)
            } catch {
                finishWait(generation: generation, error: error)
            }
        }
    }

    private func finishWait(generation: Int, error: (any Error)?) {
        guard generation == wakeGeneration else { return }
        wake = nil
        wakeDeadline = nil
        if let error {
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.continuation.resume(throwing: error) }
        } else { schedule() }
    }

    /// Current per-method costs: developers.google.com/workspace/gmail/api/reference/quota.
    static func units(method: String, path: String, format: String?) -> Int {
        let parts = path.split(separator: "/")
        guard let resource = parts.first else { return 100 }
        let reading = method == "GET"
        let full = format == nil || ["full", "raw", "html"].contains(format ?? "")
        switch resource {
        case "profile": return 1
        case "history": return 2
        case "labels": return reading ? 1 : 5
        case "messages":
            if parts.contains("attachments") { return 20 }
            if parts.count == 1 { return reading ? 5 : 25 }
            if reading { return full ? 60 : 20 }
            switch parts.last {
            case "batchDelete", "batchModify": return 50
            case "send": return 100
            case "trash": return 20
            case "modify", "untrash": return 5
            case "import", "insert": return 25
            default: return 10
            }
        case "threads":
            if parts.count == 1 { return 10 }
            if reading { return full ? 120 : 40 }
            return parts.last == "trash" || method == "DELETE" ? 20 : 10
        case "drafts":
            if reading { return parts.count == 1 ? 5 : (full ? 60 : 20) }
            if parts.last == "send" { return 100 }
            return method == "PUT" ? 15 : 10
        case "settings":
            if reading { return 1 }
            if parts.contains("sendAs") { return method == "DELETE" ? 5 : 100 }
            if parts.contains("forwardingAddresses") || parts.contains("delegates") { return method == "POST" ? 100 : 5 }
            return parts.last == "pop" ? 100 : 5
        case "watch": return 100
        case "stop": return 50
        default: return 100
        }
    }

    static func units(for request: URLRequest) -> Int {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return 100 }
        let parts = components.path.split(separator: "/")
        guard let users = parts.firstIndex(of: "users"), parts.count > users + 2 else { return 100 }
        let path = parts.dropFirst(users + 2).joined(separator: "/")
        let format = components.queryItems?.first { $0.name == "format" }?.value
        return units(method: request.httpMethod ?? "GET", path: path, format: format)
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
