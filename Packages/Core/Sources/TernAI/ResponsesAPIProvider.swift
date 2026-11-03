import Foundation

/// API-key inference through OpenAI's or DeepSeek's Responses endpoint.
public struct ResponsesAPIProvider: AIProvider {
    private let engine: ResponsesProviderEngine?

    public init(service: AIService, apiKey: @escaping @Sendable () async throws -> String,
                transport: AIHTTPTransport = .live, requestTimeout: Duration = .seconds(120)) {
        engine = service == .openAI || service == .deepSeek
            ? ResponsesProviderEngine(service: service, accessToken: apiKey, transport: transport, requestTimeout: requestTimeout)
            : nil
    }

    public func models() async throws -> [AIModel] {
        guard let engine else { throw AIProviderError.invalidRequest }
        return try await engine.models()
    }
    public func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        guard let engine else {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.invalidRequest) }
        }
        return engine.respond(request)
    }
}
