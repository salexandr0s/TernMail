import Foundation

/// One account's Gmail traffic shares this budget, including mail sync,
/// attachments and settings. Calendar and People requests use their own APIs.
///
/// Requests run in three lanes. Each lane runs one request at a time and
/// leaves part of the quota to the lanes above it, so the open conversation
/// never queues behind a history page, and a history page never queues
/// behind an attachment scan.
public actor GmailRequestBudget {
    /// 4,000 units per minute plus a 500-unit burst leaves room below the
    /// 6,000-unit per-user quota used by new Google Cloud projects.
    public static let maximumRequestUnits = 500
    /// The most one request may cost at the current priority.
    static var maximumBatchUnits: Int { maximumRequestUnits - priority.reserve }
    /// A server or network failure holds its lane back no longer than this.
    /// Gmail's own rate limit, with or without a Retry-After, is not capped.
    static let laneCooldownLimit: TimeInterval = 8

    public enum Priority: Sendable, Hashable, CaseIterable {
        /// Speculative and historical work: prefetch, attachment indexing,
        /// anything that can wait for the mailbox to go quiet.
        case background
        /// History and metadata passes.
        case sync
        /// The open conversation, search, Load Older and the user's own changes.
        case interactive

        /// Units a request at this priority leaves for the lanes above it.
        var reserve: Int {
            switch self {
            case .background: 250
            case .sync: 120
            case .interactive: 0
            }
        }

        /// Dispatch order: the reader first, then sync, then everything else.
        static let dispatchOrder: [Priority] = [.interactive, .sync, .background]
    }

    /// What a failed response asks the budget to wait for.
    public enum Cooldown: Sendable, Equatable {
        /// Gmail's rate limit, or any Retry-After: every lane of the account waits.
        case shared(TimeInterval)
        /// A server or network failure: only the lane that saw it waits.
        case lane(TimeInterval)
    }

    /// The budget's state at one instant, for diagnostics.
    public struct Snapshot: Sendable, Equatable {
        public var availableUnits: Int
        /// Seconds until the shared cooldown ends; zero when none is running.
        public var sharedCooldown: TimeInterval
        /// Seconds until each cooling lane may run again.
        public var laneCooldowns: [Priority: TimeInterval]
        public var executing: Set<Priority>
        public var waiting: [Priority: Int]
    }

    /// Inherited by requests made while opening a message. Unclassified work
    /// stays in the background lane, including speculative downloads.
    @TaskLocal public static var priority: Priority = .background
    private let unitsPerSecond: Double
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private var availableUnits: Double = Double(maximumRequestUnits)
    private var updatedAt: TimeInterval
    private var blockedUntil: TimeInterval = 0
    private var laneBlockedUntil: [Priority: TimeInterval] = [:]
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
        guard units > 0, units <= Self.maximumRequestUnits - priority.reserve else {
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
        postpone(.shared(seconds), lane: Self.priority)
    }

    /// Holds requests back after a failure: every lane for a shared cooldown,
    /// only `lane` for a lane cooldown.
    func postpone(_ cooldown: Cooldown, lane: Priority) {
        switch cooldown {
        case .shared(let seconds):
            guard seconds.isFinite, seconds > 0 else { return }
            blockedUntil = max(blockedUntil, now() + seconds)
        case .lane(let seconds):
            guard seconds.isFinite, seconds > 0 else { return }
            let until = now() + min(seconds, Self.laneCooldownLimit)
            laneBlockedUntil[lane] = max(laneBlockedUntil[lane] ?? 0, until)
        }
        schedule()
    }

    /// The wait a failed Gmail response asks for, or nil when the request
    /// should not be retried. `attempt` counts earlier tries of the same
    /// request, so each retry waits twice as long as the one before.
    static func cooldown(for error: GmailError, retryAfter header: String?, attempt: Int) -> Cooldown? {
        guard error.isRetryable else { return nil }
        if let seconds = retryAfter(header) { return .shared(max(1, seconds)) }
        let backoff = max(1, pow(2, Double(attempt)))
        switch error {
        case .rateLimited: return .shared(backoff)
        default: return .lane(min(backoff, laneCooldownLimit))
        }
    }

    public func snapshot() -> Snapshot {
        let instant = max(updatedAt, now())
        let available = min(Double(Self.maximumRequestUnits), availableUnits + (instant - updatedAt) * unitsPerSecond)
        var laneCooldowns: [Priority: TimeInterval] = [:]
        for (lane, until) in laneBlockedUntil where until > instant {
            laneCooldowns[lane] = until - instant
        }
        var waiting: [Priority: Int] = [:]
        for waiter in waiters { waiting[waiter.priority, default: 0] += 1 }
        return Snapshot(
            availableUnits: Int(available.rounded(.down)),
            sharedCooldown: max(0, blockedUntil - instant),
            laneCooldowns: laneCooldowns,
            executing: executing,
            waiting: waiting
        )
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

    /// Dispatches what can run now and sets one timer for the earliest wait.
    /// A lane in its own cooldown is skipped, so the lanes below it keep
    /// running. A lane waiting for quota stops the lanes below it, since
    /// they would take the units it is waiting for.
    private func schedule() {
        let instant = max(updatedAt, now())
        availableUnits = min(Double(Self.maximumRequestUnits), availableUnits + (instant - updatedAt) * unitsPerSecond)
        updatedAt = instant
        var nextWake: TimeInterval?
        dispatch: while true {
            for lane in Priority.dispatchOrder {
                guard !executing.contains(lane), let index = waiters.firstIndex(where: { $0.priority == lane }) else { continue }
                let laneDelay = (laneBlockedUntil[lane] ?? 0) - instant
                if laneDelay > 0 {
                    nextWake = min(nextWake ?? .infinity, laneDelay)
                    continue
                }
                let waiter = waiters[index]
                let delay = max(blockedUntil - instant, (Double(waiter.units + lane.reserve) - availableUnits) / unitsPerSecond)
                if delay > 0 {
                    nextWake = min(nextWake ?? .infinity, delay)
                    break dispatch
                }
                availableUnits -= Double(waiter.units)
                executing.insert(lane)
                waiters.remove(at: index).continuation.resume()
                continue dispatch
            }
            break
        }
        if let nextWake {
            scheduleWake(at: instant + nextWake, delay: nextWake)
        } else {
            cancelWake()
        }
    }

    private func cancelWake() {
        guard wake != nil else { return }
        wakeGeneration += 1
        wake?.cancel()
        wake = nil
        wakeDeadline = nil
    }

    private func scheduleWake(at deadline: TimeInterval, delay: TimeInterval) {
        // An interactive arrival may need only 120 units while a sync batch
        // is waiting for 500. Replace that timer instead of inheriting it.
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
