import Foundation

/// Shares pending work while each caller retains its own cancellation lifetime.
@MainActor
final class AssistantSharedRequests<Key: Equatable & Sendable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        let key: Key
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Value, any Error>]
    }
    private var entries: [Entry] = []

    isolated deinit {
        for entry in entries {
            entry.task.cancel()
            entry.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    func value(for key: Key, start: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let waiterID = UUID()
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let index = entries.firstIndex(where: { $0.key == key }) {
                    entries[index].waiters[waiterID] = continuation
                    return
                }
                let id = UUID()
                let task = Task { [weak self] in
                    let result: Result<Value, any Error>
                    do {
                        try Task.checkCancellation()
                        result = .success(try await start())
                    } catch { result = .failure(error) }
                    self?.finish(id, result: result)
                }
                entries.append(Entry(id: id, key: key, task: task, waiters: [waiterID: continuation]))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(waiterID: waiterID) }
        }
        try Task.checkCancellation()
        return value
    }

    func cancel(where predicate: (Key) -> Bool) {
        let cancelled = entries.filter { predicate($0.key) }
        entries.removeAll { predicate($0.key) }
        for entry in cancelled {
            entry.task.cancel()
            entry.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    func cancelAll() { cancel { _ in true } }

    func waiterCount(for key: Key) -> Int {
        entries.first(where: { $0.key == key })?.waiters.count ?? 0
    }

    private func cancel(waiterID: UUID) {
        guard let index = entries.firstIndex(where: { $0.waiters[waiterID] != nil }) else { return }
        let continuation = entries[index].waiters.removeValue(forKey: waiterID)
        if entries[index].waiters.isEmpty {
            let entry = entries.remove(at: index)
            entry.task.cancel()
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ id: UUID, result: Result<Value, any Error>) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.waiters.values.forEach { $0.resume(with: result) }
    }
}
