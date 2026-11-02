import Foundation
import GmailAPI
import MailStore
import os
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct SyncSchedulingTests {
    @Test func concurrentStopsWaitForTheSameBackgroundTeardown() async throws {
        let sleep = HeldSchedulerSleep()
        let (engine, cache, _, _) = try await makeEngine(sleep: { _ in await sleep.wait() })
        try await seed(cache, [], cursor: 100)
        await engine.start()
        if let passes = await engine.requestedPasses { await passes.value }
        await sleep.waitUntilEntered()

        let (entered, signal) = AsyncStream.makeStream(of: Void.self)
        var starts = entered.makeAsyncIterator()
        let first = await engine.observedStop(entered: signal, sleep: sleep)
        _ = await starts.next()
        // An actor hop after the signal waits until stop reaches its first await.
        #expect(await engine.isStopped)
        let second = await engine.observedStop(entered: signal, sleep: sleep)
        _ = await starts.next()
        #expect(await engine.isStopped)

        await sleep.release()
        await first.value
        await second.value
    }

    @Test func pollingFollowsTheActivityAndIMAP() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await withEngineStopped(engine) {
            try await seed(cache, [], cursor: 100)
            await engine.start()
            // The first pass runs at once; the next waits 15 seconds while the app is in front.
            if let passes = await engine.requestedPasses { await passes.value }
            #expect(try await clock.parked() == [SyncSchedule.activeInterval])
            #expect(await gmail.historyCalls == 1)
            #expect(await gmail.labelListRequests == 1)

            await engine.setActivity(.inactive)
            #expect(try await clock.parked() == [SyncSchedule.inactiveInterval])
            await engine.setPushAvailable(true)
            #expect(try await clock.parked() == [SyncSchedule.pushInterval])
            await engine.setActivity(.suspended)
            #expect(try await clock.parked() == [SyncSchedule.suspendedCheck])
            #expect(await gmail.historyCalls == 1)

            // Back in front 10 seconds later: a pass runs at once and lists every
            // label again, and polling counts from its end.
            clock.advance(10)
            await engine.setActivity(.active)
            if let passes = await engine.requestedPasses { await passes.value }
            #expect(await gmail.historyCalls == 2)
            #expect(await gmail.labelListRequests == 2)
            #expect(try await clock.parked() == [SyncSchedule.pushInterval])

            // The timer runs out: a pass, then the timer again.
            clock.wake()
            #expect(try await clock.parked() == [SyncSchedule.pushInterval])
            #expect(await gmail.historyCalls == 3)
        }
    }

    @Test func anActivationWithinFiveSecondsOfAPassIsAlreadyServed() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await withEngineStopped(engine) {
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
        }
    }

    @Test func deliveredChangesShareOnePassHalfASecondAfterTheLast() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await withEngineStopped(engine) {
            try await seed(cache, [], cursor: 100)

            await engine.requestSync(reason: .afterAction)
            #expect(try await clock.parked() == [SyncSchedule.afterActionDebounce])
            // The second change starts the wait over.
            await engine.requestSync(reason: .afterAction)
            #expect(try await clock.parked() == [SyncSchedule.afterActionDebounce])
            #expect(await gmail.historyCalls == 0)

            let debounce = await engine.afterActionTask
            clock.wake()
            await debounce?.value
            if let passes = await engine.requestedPasses { await passes.value }
            #expect(await gmail.historyCalls == 1)
            #expect(clock.parkedNow().isEmpty)
        }
    }

    @Test func aRequestDuringARetryWaitRunsAtOnce() async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await withEngineStopped(engine) {
            try await seed(cache, [], cursor: 100)
            await engine.requestSync(reason: .inboxSignal)
            #expect(try await clock.parked() == [.seconds(1)])
            let passes = await engine.requestedPasses
            await engine.requestSync(reason: .manual)
            await passes?.value
            #expect(await gmail.historyCalls == 2)
            #expect(clock.parkedNow().isEmpty)
        }
    }

    @Test(arguments: [SyncReason.afterAction, .inboxSignal])
    func stoppingCancelsPendingPasses(reason: SyncReason) async throws {
        let clock = SchedulerClock()
        let (engine, cache, gmail, _) = try await makeEngine(clock: clock.time, sleep: clock.sleep)
        try await withEngineStopped(engine) {
            try await seed(cache, [], cursor: 100)
            await engine.requestSync(reason: reason)
            let waiting = try await clock.parked()
            switch reason {
            case .afterAction: #expect(waiting == [SyncSchedule.afterActionDebounce])
            case .inboxSignal: #expect(waiting == [SyncSchedule.inboxSignalRetries[0]])
            default: Issue.record("Unexpected request reason")
            }
            let callsBeforeStop = await gmail.historyCalls

            await engine.stop()
            #expect(clock.parkedNow().isEmpty)
            #expect(await engine.requestedPasses == nil)
            #expect(await engine.afterActionTask == nil)
            #expect(await gmail.historyCalls == callsBeforeStop)

            await engine.requestSync(reason: reason)
            #expect(await engine.requestedPasses == nil)
            #expect(await engine.afterActionTask == nil)
        }
    }
}

private extension SyncEngine {
    func observedStop(entered: AsyncStream<Void>.Continuation, sleep: HeldSchedulerSleep) -> Task<Void, Never> {
        Task {
            entered.yield(())
            await stop()
            #expect(sleep.finished)
        }
    }
}

/// Keeps teardown suspended even after cancellation, until the test releases it.
private actor HeldSchedulerSleep {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private nonisolated let completion = OSAllocatedUnfairLock(initialState: false)
    nonisolated var finished: Bool { completion.withLock { $0 } }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in entryWaiters { waiter.resume() }
            entryWaiters = []
        }
        completion.withLock { $0 = true }
    }

    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() { continuation?.resume(); continuation = nil }
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
        var watchers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var sleep: @Sendable (Duration) async throws -> Void { { [self] in try await park($0) } }

    func advance(_ seconds: TimeInterval) { time.advance(seconds) }

    /// The sleeps under way, shortest first, once there is one.
    func parked() async throws -> [Duration] {
        while true {
            try Task.checkCancellation()
            if let durations = parkedNow().nonEmpty { return durations }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let waiting = state.withLock { state in
                        guard !Task.isCancelled, state.parked.isEmpty else { return false }
                        state.watchers[id] = continuation
                        return true
                    }
                    if !waiting { continuation.resume() }
                }
            } onCancel: {
                let watcher = state.withLock { $0.watchers.removeValue(forKey: id) }
                watcher?.resume(throwing: CancellationError())
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
                let (cancelled, watchers) = state.withLock { state -> (Bool, [CheckedContinuation<Void, any Error>]) in
                    if Task.isCancelled { return (true, []) }
                    state.parked[id] = Parked(duration: duration, continuation: continuation)
                    let watchers = Array(state.watchers.values)
                    state.watchers = [:]
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
