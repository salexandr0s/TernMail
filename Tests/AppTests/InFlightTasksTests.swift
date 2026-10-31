import Testing
@testable import Tern

@MainActor @Suite struct InFlightTasksTests {
    @MainActor private final class Counter { var starts = 0 }

    @Test func aSecondRequestWaitsForTheRunningTask() async throws {
        let tasks = InFlightTasks<String, Int>()
        let counter = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let first = Task {
            await tasks.value(for: "file") {
                counter.starts += 1
                for await _ in gate.stream { break }
                return 1
            }
        }
        for _ in 0..<10 where !tasks.isRunning("file") { await Task.yield() }
        #expect(tasks.isRunning("file"))
        let second = Task { await tasks.value(for: "file") { counter.starts += 1; return 2 } }
        await Task.yield()
        gate.continuation.finish()
        #expect(await first.value == 1)
        #expect(await second.value == 1)
        #expect(counter.starts == 1)
        #expect(!tasks.isRunning("file"))
        #expect(await tasks.value(for: "file") { 3 } == 3)
    }
}
