import Foundation
import Testing
@testable import Tern

struct KeychainIOTests {
    @Test @MainActor func blockingCredentialOperationLeavesMainActorResponsive() async throws {
        let release = DispatchSemaphore(value: 0)
        let (started, continuation) = AsyncStream<Bool>.makeStream()
        let operation = Task {
            try await KeychainIO.perform {
                continuation.yield(Thread.isMainThread)
                continuation.finish()
                // A timeout makes a regression fail rather than deadlock the suite.
                return release.wait(timeout: .now() + 2) == .success
            }
        }
        var iterator = started.makeAsyncIterator()
        let ranOnMainThread = await iterator.next()
        // This main-actor continuation must run while the operation is waiting.
        release.signal()
        #expect(ranOnMainThread == false)
        #expect(try await operation.value)
    }

    @Test func operationFailureReachesCaller() async {
        await #expect(throws: TestFailure.denied) {
            try await KeychainIO.perform { () throws -> Int in
                throw TestFailure.denied
            }
        }
    }

    private enum TestFailure: Error, Equatable { case denied }
}
