import Foundation

/// Batches display work while retaining every fragment of the current reply.
@MainActor
final class AssistantTextStream {
    private let publish: @MainActor (String) -> Void
    private let sleep: @MainActor (Duration) async throws -> Void
    private var text = ""
    private(set) var utf8Count = 0
    private var hasPublished = false
    private var hasPendingText = false
    private var isFinished = false
    private var flushTask: Task<Void, Never>?

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         publish: @escaping @MainActor (String) -> Void) {
        self.sleep = sleep
        self.publish = publish
    }

    func append(_ delta: String) {
        guard !isFinished, !delta.isEmpty else { return }
        text += delta
        utf8Count += delta.utf8.count
        hasPendingText = true
        if !hasPublished {
            flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self, sleep] in
                do {
                    try await sleep(.milliseconds(40))
                    try Task.checkCancellation()
                    self?.flushTask = nil
                    self?.flush()
                } catch { }
            }
        }
    }

    func complete(_ authoritativeText: String) {
        guard !isFinished else { return }
        text = authoritativeText
        utf8Count = text.utf8.count
        hasPendingText = true
        finish()
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    private func flush() {
        guard hasPendingText else { return }
        hasPendingText = false
        hasPublished = true
        publish(text)
    }
}
