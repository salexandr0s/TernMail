import Foundation

/// Direct ChatGPT-plan inference. Credentials come from Tern's connection manager.
public struct ChatGPTProvider: AIProvider {
    private let engine: ResponsesProviderEngine

    public init(accessToken: @escaping @Sendable () async throws -> String,
                transport: AIHTTPTransport = .live, requestTimeout: Duration = .seconds(120)) {
        engine = ResponsesProviderEngine(service: .chatGPT, accessToken: accessToken,
                                         transport: transport, requestTimeout: requestTimeout)
    }

    init(accessToken: @escaping @Sendable () async throws -> String,
         transport: AIHTTPTransport, requestTimeout: Duration,
         sleep: @escaping @Sendable (Duration) async throws -> Void) {
        engine = ResponsesProviderEngine(service: .chatGPT, accessToken: accessToken,
                                         transport: transport, requestTimeout: requestTimeout, sleep: sleep)
    }

    public func models() async throws -> [AIModel] { try await engine.models() }
    public func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> { engine.respond(request) }

    static let maximumRequestBytes = ResponsesProviderEngine.maximumRequestBytes
    static func requestBody(_ request: AIRequest) throws -> Data {
        try ResponsesProviderEngine.requestBody(request, service: .chatGPT)
    }
}
