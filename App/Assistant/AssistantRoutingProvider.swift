import Foundation
import Synchronization
import TernAI

struct AssistantRouteSnapshot: Equatable, Sendable {
    let service: AIService
    let revision: Int
    let generation: Int
}

/// Publishes selection changes synchronously to nonisolated provider callers.
final class AssistantRouteState: Sendable {
    private struct State {
        var snapshot: AssistantRouteSnapshot
        var observingMutation = false
    }
    private let state: Mutex<State>

    init(service: AIService, revision: Int) {
        state = Mutex(State(snapshot: .init(service: service, revision: revision, generation: 0)))
    }

    func capture() -> AssistantRouteSnapshot? {
        state.withLock { $0.observingMutation ? nil : $0.snapshot }
    }

    func matches(_ snapshot: AssistantRouteSnapshot) -> Bool {
        state.withLock { !$0.observingMutation && $0.snapshot == snapshot }
    }

    func invalidate() { state.withLock { $0.observingMutation = true } }

    func publish(service: AIService, revision: Int, finishObservation: Bool = false) {
        state.withLock {
            $0.snapshot = .init(service: service, revision: revision, generation: $0.snapshot.generation + 1)
            if finishObservation { $0.observingMutation = false }
        }
    }
}

struct AssistantProviderRoute: Sendable {
    let provider: any AIProvider
    let check: @Sendable () async throws -> Void
}

/// Each operation retains its initial backend and authorization revision.
struct AssistantRoutingProvider: AIProvider {
    let state: AssistantRouteState
    let route: @Sendable (AssistantRouteSnapshot) async throws -> AssistantProviderRoute

    func models() async throws -> [AIModel] {
        guard let snapshot = state.capture() else { throw CancellationError() }
        let active = try await route(snapshot)
        try await active.check()
        let models = try await active.provider.models()
        try await active.check()
        return models
    }

    func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        let snapshot = state.capture()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(4096)) { continuation in
            let task = Task {
                do {
                    guard let snapshot else { throw CancellationError() }
                    let active = try await route(snapshot)
                    try await active.check()
                    for try await event in active.provider.respond(request) {
                        try await active.check()
                        switch continuation.yield(event) {
                        case .enqueued: break
                        case .dropped: throw AIProviderError.responseLimit
                        case .terminated: throw CancellationError()
                        @unknown default: throw AIProviderError.streamInterrupted
                        }
                    }
                    try await active.check()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
