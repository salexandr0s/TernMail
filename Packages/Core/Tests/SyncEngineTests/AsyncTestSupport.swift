import Testing
@testable import SyncEngine

func waitForSyncCondition(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await condition() == false {
        try Task.checkCancellation()
        try #require(ContinuousClock.now < deadline, "The expected state was not reached within 5 seconds.", sourceLocation: sourceLocation)
        try await Task.sleep(for: .milliseconds(1))
    }
}

func withEngineStopped<T>(_ engine: SyncEngine, _ operation: () async throws -> T) async rethrows -> T {
    do {
        let result = try await operation()
        await engine.stop()
        return result
    } catch {
        await engine.stop()
        throw error
    }
}
