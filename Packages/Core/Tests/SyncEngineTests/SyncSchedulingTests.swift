import Foundation
import GmailAPI
import MailStore
import os
import Testing
@testable import SyncEngine

@Suite struct SyncSchedulingTests {
    @Test func pollingFollowsTheActivityAndIMAP() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await seed(cache, [], cursor: 100)
        await engine.start()
        // The first pass runs at once; the next waits 15 seconds while the app is in front.
        if let passes = await engine.requestedPasses { await passes.value }
        #expect(await clock.parked() == [SyncSchedule.activeInterval])
        #expect(await gmail.historyCalls == 1)
        #expect(await gmail.labelListRequests == 1)

        await engine.setActivity(.inactive)
        #expect(await clock.parked() == [SyncSchedule.inactiveInterval])
        await engine.setPushAvailable(true)
        #expect(await clock.parked() == [SyncSchedule.pushInterval])
        await engine.setActivity(.suspended)
        #expect(await clock.parked() == [SyncSchedule.suspendedCheck])
        #expect(await gmail.historyCalls == 1)

        // Back in front 10 seconds later: a pass runs at once and lists every
        // label again, and polling counts from its end.
        clock.advance(10)
        await engine.setActivity(.active)
        if let passes = await engine.requestedPasses { await passes.value }
        #expect(await gmail.historyCalls == 2)
        #expect(await gmail.labelListRequests == 2)
        #expect(await clock.parked() == [SyncSchedule.pushInterval])

        // The timer runs out: a pass, then the timer again.
        clock.wake()
        #expect(await clock.parked() == [SyncSchedule.pushInterval])
        #expect(await gmail.historyCalls == 3)
        await engine.stop()
    }

    @Test func anActivationWithinFiveSecondsOfAPassIsAlreadyServed() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await seed(cache, [], cursor: 100)
        try await engine.sync()
        #expect(await gmail.historyCalls == 1)

        clock.advance(4)
        await engine.requestSync(reason: .activation)
        #expect(await engine.requestedPasses == nil)
        #expect(await gmail.historyCalls == 1)

        clock.advance(2)
        await engine.requestSync(reason: .activation)
        if let passes = await engine.requestedPasses { await passes.value }
        #expect(await gmail.historyCalls == 2)
        await engine.stop()
    }

    @Test func deliveredChangesShareOnePassHalfASecondAfterTheLast() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await seed(cache, [], cursor: 100)

        await engine.requestSync(reason: .afterAction)
        #expect(await clock.parked() == [SyncSchedule.afterActionDebounce])
        // The second change starts the wait over.
        await engine.requestSync(reason: .afterAction)
        #expect(await clock.parked() == [SyncSchedule.afterActionDebounce])
        #expect(await gmail.historyCalls == 0)

        let debounce = await engine.afterActionTask
        clock.wake()
        await debounce?.value
        if let passes = await engine.requestedPasses { await passes.value }
        #expect(await gmail.historyCalls == 1)
        #expect(clock.parkedNow().isEmpty)
        await engine.stop()
    }

    @Test func aRequestDuringARetryWaitRunsAtOnce() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await seed(cache, [], cursor: 100)
        await engine.requestSync(reason: .inboxSignal)
        #expect(await clock.parked() == [.seconds(1)])
        let passes = await engine.requestedPasses
        await engine.requestSync(reason: .manual)
        await passes?.value
        #expect(await gmail.historyCalls == 2)
        #expect(clock.parkedNow().isEmpty)
        await engine.stop()
    }
}

/// Parks every sleep the engine asks for until the test ends it, so each
/// wait shows as its duration. `time` is the engine's clock.
final class SchedulerClock: Sendable {
    let time = TestClock()

    private struct Parked {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var parked: [UUID: Parked] = [:]
        var watchers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var sleep: @Sendable (Duration) async throws -> Void { { [self] in try await park($0) } }

    func advance(_ seconds: TimeInterval) { time.advance(seconds) }

    /// The sleeps under way, shortest first, once there is one.
    func parked() async -> [Duration] {
        while true {
            if let durations = parkedNow().nonEmpty { return durations }
            await withCheckedContinuation { continuation in
                let waiting = state.withLock { state in
                    guard state.parked.isEmpty else { return false }
                    state.watchers.append(continuation)
                    return true
                }
                if !waiting { continuation.resume() }
            }
        }
    }

    /// The sleeps under way right now, shortest first.
    func parkedNow() -> [Duration] {
        state.withLock { $0.parked.values.map(\.duration).sorted() }
    }

    /// Ends every sleep under way, as if its time had come.
    func wake() {
        let parked = state.withLock { state in
            let parked = Array(state.parked.values)
            state.parked = [:]
            return parked
        }
        for sleep in parked { sleep.continuation.resume() }
    }

    private func park(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (cancelled, watchers) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (true, []) }
                    state.parked[id] = Parked(duration: duration, continuation: continuation)
                    let watchers = state.watchers
                    state.watchers = []
                    return (false, watchers)
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                for watcher in watchers { watcher.resume() }
            }
        } onCancel: {
            let parked = state.withLock { $0.parked.removeValue(forKey: id) }
            parked?.continuation.resume(throwing: CancellationError())
        }
    }
}

private extension Array {
    var nonEmpty: [Element]? { isEmpty ? nil : self }
}
