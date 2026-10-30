import Foundation
import IMAPIdle
import Testing
@testable import Tern

@MainActor
@Suite struct InboxWatcherTests {
    @Test func signalsRequestSyncAndStoppingRejectsLateSignals() async throws {
        let monitor = TestInboxMonitor()
        let counter = InboxSyncCounter()
        let watcher = InboxWatcher(monitor: monitor, observesSystemEvents: false) { await counter.increment() }
        watcher.start()
        watcher.start()
        try await eventually { await monitor.starts == 1 }
        await monitor.signal()
        try await eventually { await counter.count == 1 }
        #expect(watcher.state == .watching)
        await watcher.stop()
        await monitor.signal()
        #expect(watcher.state == .stopped)
        #expect(await counter.count == 1)
        #expect(await monitor.stops == 1)
    }

    @Test func networkRestorationReconnectsButInitialDeliveryDoesNot() async throws {
        let monitor = TestInboxMonitor()
        let watcher = InboxWatcher(monitor: monitor, observesSystemEvents: false) {}
        watcher.start()
        try await eventually { await monitor.starts == 1 }
        watcher.networkChanged(isAvailable: true)
        watcher.networkChanged(isAvailable: false)
        watcher.networkChanged(isAvailable: true)
        try await eventually { await monitor.reconnects == 1 }
        watcher.networkChanged(isAvailable: true)
        await watcher.stop()
        watcher.reconnect()
        #expect(await monitor.reconnects == 1)
    }

    @Test func transientTokenFailureRetriesAndStopCancelsRetry() async throws {
        let monitor = TestInboxMonitor()
        let watcher = InboxWatcher(monitor: monitor, observesSystemEvents: false, retryDelay: .milliseconds(10)) {}
        watcher.start()
        try await eventually { await monitor.starts == 1 }
        await monitor.fail(URLError(.notConnectedToInternet))
        try await eventually { await monitor.starts == 2 }
        await monitor.signal()
        try await eventually { watcher.state == .watching }
        await watcher.stop()
        #expect(await monitor.starts == 2)
    }

    @Test func permanentFailureDoesNotLoopAndWakeCanRetry() async throws {
        let monitor = TestInboxMonitor()
        let watcher = InboxWatcher(monitor: monitor, observesSystemEvents: false, retryDelay: .milliseconds(1)) {}
        watcher.start()
        try await eventually { await monitor.starts == 1 }
        await monitor.fail(InboxMonitor.Failure.unsupported)
        try await eventually { if case .unavailable = watcher.state { true } else { false } }
        #expect(await monitor.starts == 1)
        watcher.reconnect()
        try await eventually { await monitor.starts == 2 }
        await watcher.stop()
    }

    @Test func networkRestorationInterruptsTransientRetryAndStoppedWatcherCanResume() async throws {
        let monitor = TestInboxMonitor()
        let watcher = InboxWatcher(monitor: monitor, observesSystemEvents: false, retryDelay: .seconds(3600)) {}
        watcher.start()
        try await eventually { await monitor.starts == 1 }
        await monitor.fail(URLError(.notConnectedToInternet))
        try await eventually { if case .unavailable = watcher.state { true } else { false } }
        watcher.networkChanged(isAvailable: false)
        watcher.networkChanged(isAvailable: true)
        try await eventually { await monitor.starts == 2 }
        await watcher.stop()
        watcher.start()
        try await eventually { await monitor.starts == 3 }
        await watcher.stop()
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

private actor TestInboxMonitor: InboxMonitoring {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var reconnects = 0
    private var continuation: AsyncThrowingStream<Void, any Error>.Continuation?

    func signals() -> AsyncThrowingStream<Void, any Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func signal() { continuation?.yield() }
    func fail(_ error: any Error) { continuation?.finish(throwing: error) }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
    func reconnectNow() { reconnects += 1 }
}

private actor InboxSyncCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
