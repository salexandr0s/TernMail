import Testing
@testable import IMAPIdle

@Suite struct IdleTimersTests {
    @Test func replacingATimerRejectsItsAlreadyBufferedExpiration() async throws {
        let (events, output) = AsyncStream<IdleTimers.Expiration>.makeStream()
        var iterator = events.makeAsyncIterator()
        var timers = IdleTimers()
        defer {
            timers.cancelAll()
            output.finish()
        }

        // Wait for the old event to be enqueued, as if a server response were
        // ahead of it in the monitor's input stream.
        timers.start(.reply, after: .zero) { output.yield($0) }
        let old = try #require(await iterator.next())
        timers.start(.reply, after: .zero) { output.yield($0) }
        let current = try #require(await iterator.next())

        let acceptedOld = timers.consume(old)
        let acceptedCurrent = timers.consume(current)
        let acceptedDuplicate = timers.consume(current)
        #expect(!acceptedOld)
        #expect(acceptedCurrent)
        #expect(!acceptedDuplicate)
    }

    @Test func cancellingATimerRejectsItsAlreadyBufferedExpiration() async throws {
        let (events, output) = AsyncStream<IdleTimers.Expiration>.makeStream()
        var iterator = events.makeAsyncIterator()
        var timers = IdleTimers()
        defer {
            timers.cancelAll()
            output.finish()
        }

        timers.start(.idleRestart, after: .zero) { output.yield($0) }
        let old = try #require(await iterator.next())
        timers.cancel(.idleRestart)
        let acceptedCancelled = timers.consume(old)
        #expect(!acceptedCancelled)

        timers.start(.reply, after: .zero) { output.yield($0) }
        let current = try #require(await iterator.next())
        timers.cancelAll()
        let acceptedAfterTeardown = timers.consume(current)
        #expect(!acceptedAfterTeardown)
    }
}
