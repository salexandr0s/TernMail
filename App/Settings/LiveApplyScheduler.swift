import Observation
import SwiftUI

/// Debounces a field that applies as the user types. One write runs at a
/// time; edits made while a write is in flight wait for the next pause.
@MainActor @Observable
final class LiveApplyScheduler {
    /// True from the first edit until the write that covers it has returned.
    private(set) var isWaiting = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var pending: (@MainActor () async -> Void)?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var generation = 0

    func schedule(_ apply: @escaping @MainActor () async -> Void) {
        timer?.cancel()
        pending = apply
        isWaiting = true
        generation &+= 1
        let generation = generation
        timer = Task { [weak self] in
            do { try await Task.sleep(for: Tokens.Settings.liveApplyDelay) } catch { return }
            guard let self, self.generation == generation else { return }
            timer = nil
            await run()
        }
    }

    /// Writes any pending edit now instead of after the pause.
    func flush() async {
        timer?.cancel()
        timer = nil
        await run()
    }

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while let next = pending, timer == nil {
            pending = nil
            await next()
        }
        isWaiting = pending != nil
    }
}
