import Foundation

public struct AIModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public init(id: String, displayName: String) { self.id = id; self.displayName = displayName }
}

public struct AIToolDefinition: Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: AIJSON
    public init(name: String, description: String, parameters: AIJSON) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public struct AIToolCall: Identifiable, Equatable, Sendable {
    public let id: String
    public let namespace: String
    public let name: String
    public let arguments: String
    public init(id: String, namespace: String, name: String, arguments: String) {
        self.id = id; self.namespace = namespace; self.name = name; self.arguments = arguments
    }
}

public struct AIUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
    }
}

public struct AIResponse: Equatable, Sendable {
    public let output: [AIJSON]
    public let text: String
    public let toolCalls: [AIToolCall]
    public let usage: AIUsage?
    public init(output: [AIJSON], text: String, toolCalls: [AIToolCall], usage: AIUsage? = nil) {
        self.output = output; self.text = text; self.toolCalls = toolCalls; self.usage = usage
    }
}

public struct AIRequest: Sendable {
    public let model: String
    public let input: [AIJSON]
    public let instructions: String
    public let tools: [AIToolDefinition]
    public let responseSchema: AIJSON?
    public init(model: String, input: [AIJSON], instructions: String, tools: [AIToolDefinition] = [], responseSchema: AIJSON? = nil) {
        self.model = model; self.input = input; self.instructions = instructions; self.tools = tools; self.responseSchema = responseSchema
    }
}

public enum AIEvent: Equatable, Sendable {
    case textDelta(String)
    case completed(AIResponse)
}

public protocol AIProvider: Sendable {
    func models() async throws -> [AIModel]
    func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error>
}

/// Static protocol locations; never contains text received from the provider.
public enum AIResponseValidationStage: String, Equatable, Sendable {
    case httpResponse = "http-response"
    case jsonDecoding = "json-decoding"
    case contentType = "content-type"
    case eventEncoding = "event-encoding"
    case eventJSON = "event-json"
    case eventEnvelope = "event-envelope"
    case deltaPayload = "delta-payload"
    case terminalEnvelope = "terminal-envelope"
    case terminalOutput = "terminal-output"
    case assistantMessage = "assistant-message"
    case outputContent = "output-content"
    case outputItem = "output-item"
    case functionCall = "function-call"
    case usage = "usage"
}

public enum AIProviderError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest, invalidResponse, responseLimit, catalogueLimit, streamInterrupted, incomplete
    case signInRequired, planUnavailable, usageLimit, rateLimited, unavailable, timedOut, network
    case httpRejected(status: Int, code: String?, parameter: String?)
    case malformedResponse(AIResponseValidationStage)
    case emptyOutput(eventCounts: [String: Int])

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "This request could not be sent to ChatGPT. Start a new chat or use less context."
        case .invalidResponse: "ChatGPT returned a response Tern could not read."
        case .responseLimit: "This response exceeded Tern's size limit. Try a narrower request."
        case .catalogueLimit: "ChatGPT's model catalogue exceeded Tern's supported size. Update Tern and refresh the model list."
        case .streamInterrupted: "The response stopped before ChatGPT finished. Try again."
        case .incomplete: "ChatGPT could not complete this response. Try a narrower request."
        case .signInRequired: "Sign in to ChatGPT again to continue."
        case .planUnavailable: "ChatGPT plan usage is unavailable for this connection. Check its access in ChatGPT."
        case .usageLimit: "This connection has reached its ChatGPT usage limit. Manage usage in ChatGPT."
        case .rateLimited: "ChatGPT is receiving too many requests. Try again shortly."
        case .unavailable: "ChatGPT is unavailable. Try again shortly."
        case .timedOut: "ChatGPT took too long to respond. Try again."
        case .network: "Tern could not reach ChatGPT. Check your connection and try again."
        case .httpRejected(let status, let code, let parameter):
            "ChatGPT rejected the request (HTTP \(status)\(code.map { "; code: \($0)" } ?? "")\(parameter.map { "; parameter: \($0)" } ?? ""))."
        case .malformedResponse(let stage): "ChatGPT returned a response Tern could not read (stage: \(stage.rawValue))."
        case .emptyOutput: "ChatGPT finished without an answer. Try again or start a new chat."
        }
    }
}

/// Transport injection keeps protocol tests independent of live credentials.
public struct AIHTTPResponse: Sendable {
    public let status: Int
    public let contentType: String?
    public let body: AsyncThrowingStream<Data, any Error>
    public let cancel: @Sendable () -> Void
    public init(status: Int, contentType: String?, body: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status; self.contentType = contentType; self.body = body; self.cancel = cancel
    }
}

public struct AIHTTPTransport: Sendable {
    public let send: @Sendable (URLRequest) async throws -> AIHTTPResponse
    public init(send: @escaping @Sendable (URLRequest) async throws -> AIHTTPResponse) { self.send = send }

    public static let live = AIHTTPTransport { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: AIRedirectBlocker(), delegateQueue: nil)
        return try await withTaskCancellationHandler {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else {
                    session.invalidateAndCancel()
                    throw AIProviderError.malformedResponse(.httpResponse)
                }
                // At most 2 MiB can wait for the parser, including a large completed-event frame.
                let body = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(2048)) { continuation in
                    let task = Task {
                        defer { session.invalidateAndCancel() }
                        do {
                            var chunk = Data()
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                chunk.append(byte)
                                if byte == 10 || chunk.count == 1024 {
                                    if case .dropped = continuation.yield(chunk) { throw AIProviderError.responseLimit }
                                    chunk.removeAll(keepingCapacity: true)
                                }
                            }
                            if !chunk.isEmpty, case .dropped = continuation.yield(chunk) { throw AIProviderError.responseLimit }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
                }
                return AIHTTPResponse(status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"), body: body,
                                      cancel: { session.invalidateAndCancel() })
            } catch {
                session.invalidateAndCancel()
                throw error
            }
        } onCancel: { session.invalidateAndCancel() }
    }
}

private final class AIRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
