import Foundation
import os
import Testing
@testable import GmailAPI

@Suite(.timeLimit(.minutes(1))) struct GmailRequestPriorityTests {
    @Test func interactiveReadStartsWhileBackgroundResponseIsPending() async throws {
        let budget = GmailRequestBudget()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let background = Task {
            try await budget.perform(units: 380) {
                started.continuation.yield(())
                for await _ in release.stream { break }
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        // The full thread read uses the reserved units and its own HTTP slot.
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        release.continuation.finish()
        try await background.value
    }

    @Test func interactiveReadOvertakesABackgroundQuotaWait() async throws {
        let sleeping = AsyncStream<Void>.makeStream()
        let budget = GmailRequestBudget(sleep: { _ in
            sleeping.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
        })
        try await budget.perform(units: 380) {}
        let background = Task {
            try await budget.perform(units: 380) { Issue.record("Background batch bypassed its quota wait") }
        }
        var iterator = sleeping.stream.makeAsyncIterator()
        _ = await iterator.next()
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        background.cancel()
        await #expect(throws: CancellationError.self) { try await background.value }
    }

    @Test func interactiveArrivalReplacesTheLongerBackgroundTimer() async throws {
        let clock = PriorityClock()
        let sleeping = AsyncStream<Void>.makeStream()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { duration in
            let call = calls.withLock { value in value += 1; return value }
            if call == 2 {
                clock.advance(duration)
            } else {
                sleeping.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
            }
        })
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 500) {}
        }
        let background = Task { try await budget.perform(units: 380) {} }
        var iterator = sleeping.stream.makeAsyncIterator()
        _ = await iterator.next()
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        // A full thread needs 1.8 seconds of refill, not the batch's 7.5 seconds.
        #expect(abs(clock.instant - 1.8) < 0.001)
        background.cancel()
        await #expect(throws: CancellationError.self) { try await background.value }
    }

    @Test func interactiveReadsHonorSharedCooldownAndTokenAccounting() async throws {
        let clock = PriorityClock()
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { clock.advance($0) })
        try await budget.perform(units: 380) {}
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        try await budget.perform(units: 380) {}
        #expect(abs(clock.instant - 7.5) < 0.001)
        await budget.postpone(for: 23)
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        #expect(abs(clock.instant - 30.5) < 0.001)
    }

    @Test func cancellingQueuedInteractiveReadPreservesQuotaAndReleasesLane() async throws {
        let clock = PriorityClock()
        let sleeping = AsyncStream<Void>.makeStream()
        let suspended = OSAllocatedUnfairLock(initialState: true)
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { duration in
            if suspended.withLock({ $0 }) {
                sleeping.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
            } else { clock.advance(duration) }
        })
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 500) {}
        }
        let pending = Task {
            try await GmailRequestBudget.$priority.withValue(.interactive) {
                try await budget.perform(units: 120) { Issue.record("Cancelled read was dispatched") }
            }
        }
        var iterator = sleeping.stream.makeAsyncIterator()
        _ = await iterator.next()
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        suspended.withLock { $0 = false }
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 500) {}
        }
        #expect(abs(clock.instant - 7.5) < 0.001)
    }
}

private struct PriorityClock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: TimeInterval.zero)
    var instant: TimeInterval { time.withLock { $0 } }
    func advance(_ duration: Duration) {
        let parts = duration.components
        time.withLock { $0 += Double(parts.seconds) + Double(parts.attoseconds) / 1e18 }
    }
}
