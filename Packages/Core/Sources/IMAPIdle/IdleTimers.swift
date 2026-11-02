import Foundation

/// Timer tasks and the identities used to reject events buffered before cancellation.
struct IdleTimers {
    struct Expiration: Sendable, Equatable {
        let timer: IdleSession.Timer
        fileprivate let id = UUID()
    }

    private struct Registration {
        let expiration: Expiration
        let task: Task<Void, Never>
    }

    private var registrations: [IdleSession.Timer: Registration] = [:]

    mutating func start(
        _ timer: IdleSession.Timer,
        after delay: Duration,
        expired: @escaping @Sendable (Expiration) -> Void
    ) {
        cancel(timer)
        let expiration = Expiration(timer: timer)
        let task = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            if !Task.isCancelled { expired(expiration) }
        }
        registrations[timer] = Registration(expiration: expiration, task: task)
    }

    mutating func cancel(_ timer: IdleSession.Timer) {
        registrations.removeValue(forKey: timer)?.task.cancel()
    }

    /// Cancellation cannot retract an event already in the input stream.
    mutating func consume(_ expiration: Expiration) -> Bool {
        guard registrations[expiration.timer]?.expiration == expiration else { return false }
        registrations[expiration.timer] = nil
        return true
    }

    mutating func cancelAll() {
        registrations.values.forEach { $0.task.cancel() }
        registrations.removeAll()
    }
}
