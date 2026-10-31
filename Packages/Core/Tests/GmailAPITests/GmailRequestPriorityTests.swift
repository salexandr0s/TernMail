import Foundation
import os
import Testing
@testable import GmailAPI

@Suite(.timeLimit(.minutes(1))) struct GmailRequestPriorityTests {
    @Test func interactiveReadStartsWhileASyncResponseIsPending() async throws {
        let budget = GmailRequestBudget()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let page = Task {
            try await GmailRequestBudget.$priority.withValue(.sync) {
                try await budget.perform(units: 380) {
                    started.continuation.yield(())
                    for await _ in release.stream { break }
                }
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        // The full thread read uses the reserved units and its own HTTP slot.
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        release.continuation.finish()
        try await page.value
    }

    @Test func interactiveReadOvertakesASyncQuotaWait() async throws {
        let sleeping = AsyncStream<Void>.makeStream()
        let budget = GmailRequestBudget(sleep: { _ in
            sleeping.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
        })
        try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 380) {} }
        let page = Task {
            try await GmailRequestBudget.$priority.withValue(.sync) {
                try await budget.perform(units: 380) { Issue.record("Sync batch bypassed its quota wait") }
            }
        }
        var iterator = sleeping.stream.makeAsyncIterator()
        _ = await iterator.next()
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        page.cancel()
        await #expect(throws: CancellationError.self) { try await page.value }
    }

    @Test func interactiveArrivalReplacesTheLongerSyncTimer() async throws {
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
        let page = Task {
            try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 380) {} }
        }
        var iterator = sleeping.stream.makeAsyncIterator()
        _ = await iterator.next()
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        // A full thread needs 1.8 seconds of refill, not the batch's 7.5 seconds.
        #expect(abs(clock.instant - 1.8) < 0.001)
        page.cancel()
        await #expect(throws: CancellationError.self) { try await page.value }
    }

    @Test func interactiveReadsHonorSharedCooldownAndTokenAccounting() async throws {
        let clock = PriorityClock()
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { clock.advance($0) })
        try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 380) {} }
        try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await budget.perform(units: 120) {}
        }
        try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 380) {} }
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

    @Test func eachLaneLeavesItsReserveForTheLanesAbove() async throws {
        let clock = PriorityClock()
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { clock.advance($0) })
        // A background request may take at most 250 units, a sync batch 380.
        await #expect(throws: GmailError.invalidRequest("Gmail request exceeds its quota budget")) {
            try await budget.perform(units: 251) {}
        }
        try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 380) {} }
        // 120 units remain: the reader runs at once, the next history page refills first.
        try await GmailRequestBudget.$priority.withValue(.interactive) { try await budget.perform(units: 120) {} }
        #expect(clock.instant == 0)
        try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 2) {} }
        #expect(abs(clock.instant - 1.83) < 0.001)
    }

    @Test func aServerFailureCoolsOnlyTheLaneThatSawIt() async throws {
        let clock = PriorityClock()
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { clock.advance($0) })
        await budget.postpone(.lane(30), lane: .interactive)
        #expect(await budget.snapshot().laneCooldowns[.interactive].map { abs($0 - 8) < 0.001 } == true)
        // The history pass is unaffected.
        try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 2) {} }
        #expect(clock.instant == 0)
        // The reader waits, but no longer than the lane limit.
        try await GmailRequestBudget.$priority.withValue(.interactive) { try await budget.perform(units: 120) {} }
        #expect(abs(clock.instant - 8) < 0.001)
    }

    @Test func aCoolingLaneDoesNotHoldTheLanesBelowIt() async throws {
        let clock = PriorityClock()
        let sleeping = AsyncStream<Void>.makeStream()
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { _ in
            sleeping.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
        })
        await budget.postpone(.lane(8), lane: .interactive)
        let reader = Task {
            try await GmailRequestBudget.$priority.withValue(.interactive) {
                try await budget.perform(units: 120) { Issue.record("Cooling read was dispatched") }
            }
        }
        var iterator = sleeping.stream.makeAsyncIterator()
        _ = await iterator.next()
        // The reader is first in line but cooling, so the page behind it runs.
        try await GmailRequestBudget.$priority.withValue(.sync) { try await budget.perform(units: 2) {} }
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
    }

    @Test func aRateLimitCoolsEveryLane() async throws {
        let clock = PriorityClock()
        let budget = GmailRequestBudget(now: { clock.instant }, sleep: { clock.advance($0) })
        await budget.postpone(.shared(5), lane: .background)
        try await GmailRequestBudget.$priority.withValue(.interactive) { try await budget.perform(units: 1) {} }
        #expect(abs(clock.instant - 5) < 0.001)
    }

    @Test func cooldownsFollowTheKindOfFailure() {
        #expect(GmailRequestBudget.cooldown(for: .rateLimited, retryAfter: nil, attempt: 0) == .shared(1))
        #expect(GmailRequestBudget.cooldown(for: .rateLimited, retryAfter: nil, attempt: 3) == .shared(8))
        #expect(GmailRequestBudget.cooldown(for: .server(status: 503), retryAfter: "30", attempt: 0) == .shared(30))
        #expect(GmailRequestBudget.cooldown(for: .server(status: 503), retryAfter: nil, attempt: 1) == .lane(2))
        #expect(GmailRequestBudget.cooldown(for: .transport(.timedOut), retryAfter: nil, attempt: 5) == .lane(8))
        #expect(GmailRequestBudget.cooldown(for: .notFound, retryAfter: "30", attempt: 0) == nil)
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
