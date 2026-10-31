import Observation

/// One task per key at a time. A request for a key that is already running
/// waits for that task's result instead of starting another.
@MainActor @Observable
final class InFlightTasks<Key: Hashable, Value: Sendable> {
    private var running: [Key: Task<Value, Never>] = [:]

    func isRunning(_ key: Key) -> Bool { running[key] != nil }

    func value(for key: Key, start: @escaping @MainActor @Sendable () async -> Value) async -> Value {
        if let task = running[key] { return await task.value }
        let task = Task { await start() }
        running[key] = task
        let value = await task.value
        running[key] = nil
        return value
    }
}
