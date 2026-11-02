#if DEBUG || TERN_PERFORMANCE
import Foundation
import os

/// One pending main-actor hop at a time, enabled only by the synthetic audit.
/// Queue latency detects stalls; it does not measure GPU frame presentation.
@MainActor
final class PerformanceMainThreadAudit {
    struct Result: Codable {
        let measurement: String
        let sampleCount: Int
        let stallsOver100ms: Int
        let maximumQueueWaitMilliseconds: Double
        let recentQueueWait: NavigationPerformance.Summary?
    }

    private struct State: Sendable {
        var values: [Double] = []
        var next = 0
        var count = 0
        var stalls = 0
        var maximum = 0.0

        mutating func append(_ milliseconds: Double) {
            count += 1
            if milliseconds >= 100 { stalls += 1 }
            maximum = max(maximum, milliseconds)
            if values.count < 6_000 { values.append(milliseconds) }
            else { values[next] = milliseconds; next = (next + 1) % values.count }
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var task: Task<Void, Never>?

    init() {
        let state = self.state
        task = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let queued = ContinuousClock.now
                await MainActor.run {
                    let delay = NavigationPerformance.milliseconds(queued.duration(to: .now))
                    state.withLock { $0.append(delay) }
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
    }

    func stop() async -> Result {
        task?.cancel()
        await task?.value
        task = nil
        return state.withLock {
            Result(measurement: "Background heartbeat to main-actor execution latency; one pending hop; not GPU frame timing",
                   sampleCount: $0.count, stallsOver100ms: $0.stalls, maximumQueueWaitMilliseconds: $0.maximum,
                   recentQueueWait: NavigationPerformance.Summary($0.values))
        }
    }
}
#endif
