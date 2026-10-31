import Foundation

/// One account's Gmail traffic shares this budget, including mail sync,
/// attachments and settings. Calendar and People requests use their own APIs.
public actor GmailRequestBudget {
    /// 4,000 units per minute plus a 500-unit burst leaves room below the
    /// 6,000-unit per-user quota used by new Google Cloud projects.
    public static let maximumRequestUnits = 500
    private let unitsPerSecond: Double
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private var availableUnits: Double = Double(maximumRequestUnits)
    private var updatedAt: TimeInterval
    private var blockedUntil: TimeInterval = 0
    private var isExecuting = false
    private var waiters: [Waiter] = []
    private var wake: Task<Void, Never>?
    private var wakeGeneration = 0

    private struct Waiter {
        let id: UUID
        let units: Int
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
        guard units > 0, units <= Self.maximumRequestUnits else {
            throw GmailError.invalidRequest("Gmail request exceeds its quota budget")
        }
        try await acquire(units: units)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            isExecuting = false
            schedule()
            return value
        } catch {
            isExecuting = false
            schedule()
            throw error
        }
    }

    /// Retry-After applies to every Gmail caller sharing this account.
    func postpone(for seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        blockedUntil = max(blockedUntil, now() + seconds)
    }

    private func acquire(units: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, units: units, continuation: continuation))
                schedule()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        if waiters.isEmpty {
            wakeGeneration += 1
            wake?.cancel()
            wake = nil
        } else if index == 0 {
            wakeGeneration += 1
            wake?.cancel()
            wake = nil
            schedule()
        }
    }

    private func schedule() {
        guard !isExecuting, wake == nil, let first = waiters.first else { return }
        let instant = max(updatedAt, now())
        availableUnits = min(Double(Self.maximumRequestUnits), availableUnits + (instant - updatedAt) * unitsPerSecond)
        updatedAt = instant
        let delay = max(blockedUntil - instant, (Double(first.units) - availableUnits) / unitsPerSecond)
        if delay <= 0 {
            availableUnits -= Double(first.units)
            isExecuting = true
            waiters.removeFirst().continuation.resume()
            return
        }
        wakeGeneration += 1
        let generation = wakeGeneration
        wake = Task { [sleep] in
            do {
                // Recheck long provider cooldowns without enormous timer values.
                try await sleep(.seconds(min(max(delay, 0.001), 60)))
                finishWait(generation: generation, error: nil)
            } catch {
                finishWait(generation: generation, error: error)
            }
        }
    }

    private func finishWait(generation: Int, error: (any Error)?) {
        guard generation == wakeGeneration else { return }
        wake = nil
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
