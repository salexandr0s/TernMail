import Foundation
import Synchronization
import Testing
@testable import TernAI

@Suite struct ResponsesAPIProviderTests {
    @Test func apiCataloguesFilterUnsupportedModelsAndKeepImageCapabilities() async throws {
        let recorder = APIRequestRecorder()
        let openAI = ResponsesAPIProvider(service: .openAI, apiKey: { "openai-test-key" }, transport: AIHTTPTransport { request in
            await recorder.append(request)
            return Self.response(#"{"data":[{"id":"gpt-6.1-sol"},{"id":"text-embedding-3-small"},{"id":"gpt-4o-2024-05-13"},{"id":"gpt-4o-2024-08-06"},{"id":"gpt-4o-audio-preview"},{"id":"gpt-5.4-mini"},{"id":"gpt-6-unknown"}]}"#, mime: "application/json")
        })
        let models = try await openAI.models()
        #expect(Set(models.map(\.id)) == ["gpt-6.1-sol", "gpt-4o-2024-08-06", "gpt-5.4-mini"])
        #expect(models.allSatisfy { $0.supportsImages })
        let deepSeek = ResponsesAPIProvider(service: .deepSeek, apiKey: { "deepseek-test-key" }, transport: AIHTTPTransport { request in
            await recorder.append(request)
            return Self.response(#"{"data":[{"id":"deepseek-flash","name":"DeepSeek Flash","input_modalities":["text","image"]},{"id":"deepseek-v4-pro","name":"DeepSeek Pro","input_modalities":["text"]},{"id":"unknown-model"}]}"#, mime: "application/json")
        })
        #expect(try await deepSeek.models() == [AIModel(id: "deepseek-flash", displayName: "DeepSeek Flash"),
                                              AIModel(id: "deepseek-v4-pro", displayName: "DeepSeek Pro", supportsImages: false)])
        let requests = await recorder.requests
        #expect(requests.map { $0.url?.absoluteString } == ["https://api.openai.com/v1/models", "https://api.deepseek.com/models"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer openai-test-key", "Bearer deepseek-test-key"])
    }

    @Test(arguments: [AIService.openAI, .deepSeek])
    func apiWireContractsRoundTripToolsAndStructuredResponses(service: AIService) async throws {
        let recorder = APIRequestRecorder()
        let stream = try Self.event(.object(["type": .string("response.output_text.delta"), "delta": .string("Searching")]))
            + Self.completed([Self.toolCall])
        let provider = ResponsesAPIProvider(service: service, apiKey: { "api-test-key" }, transport: AIHTTPTransport { request in
            await recorder.append(request)
            return Self.response(stream)
        })
        let events = try await Self.collect(provider.respond(Self.request(service, tools: [Self.tool], schema: Self.schema)))
        #expect(events.first == .textDelta("Searching"))
        guard case .completed(let result) = events.last else { Issue.record("Missing completed response"); return }
        #expect(result.toolCalls == [AIToolCall(id: "call_1", namespace: "tern", name: "search_mail", arguments: "{}")])
        #expect(result.output.first?["namespace"] == .string("tern"))
        #expect(result.usage == AIUsage(inputTokens: 3, outputTokens: 2, totalTokens: 5))

        let replay = Self.request(service, input: [Self.user] + result.output + [.object([
            "type": .string("function_call_output"), "call_id": .string("call_1"), "output": .string("{}")
        ])], tools: [Self.tool])
        _ = try await Self.collect(provider.respond(replay))
        let requests = await recorder.requests
        let expectedURL = service == .openAI ? "https://api.openai.com/v1/responses" : "https://api.deepseek.com/responses"
        #expect(requests.allSatisfy { $0.url?.absoluteString == expectedURL })
        let body = try AIJSON.decode(try #require(requests.first?.httpBody))
        #expect(body["tools"]?.arrayValue?.first?["type"] == .string("function"))
        #expect(body["tools"]?.arrayValue?.first?["name"] == .string("search_mail"))
        #expect(body["text"]?["format"]?["schema"] == Self.schema)
        if service == .deepSeek {
            #expect(body["store"] == nil && body["include"] == nil)
            #expect(body["reasoning"]?["effort"] == .string("none"))
            #expect(body["tools"]?.arrayValue?.first?["strict"] == nil)
            #expect(body["text"]?["format"]?["strict"] == nil)
        } else {
            #expect(body["store"] == .bool(false))
            #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
            #expect(body["tools"]?.arrayValue?.first?["strict"] == .bool(true))
        }
        let replayBody = try AIJSON.decode(try #require(requests.last?.httpBody))
        #expect(replayBody["input"]?.arrayValue?[1]["namespace"] == nil)
        #expect(replayBody["input"]?.arrayValue?[1]["call_id"] == .string("call_1"))
        #expect(replayBody["input"]?.arrayValue?[2]["type"] == .string("function_call_output"))
    }

    @Test func deepSeekRejectsImagesForTextOnlyModelBeforeCredentialLookup() async throws {
        let provider = ResponsesAPIProvider(service: .deepSeek, apiKey: {
            Issue.record("Unsupported image request must fail before credentials are read")
            return "unused"
        }, transport: AIHTTPTransport { _ in
            Issue.record("Unsupported image request must not reach the network")
            return Self.response("")
        })
        let input: AIJSON = .object(["role": .string("user"), "content": .array([
            .object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64,ZmFrZQ==")])
        ])])
        let request = AIRequest(model: "deepseek-v4-pro", input: [input], instructions: "Describe the image.")
        await #expect(throws: AIProviderError.unsupportedImages) { try await Self.collect(provider.respond(request)) }
    }

    @Test(arguments: [AIService.openAI, .deepSeek])
    func unfinishedToolCallCannotReachTheApp(service: AIService) async throws {
        let provisional = try Self.event(.object(["type": .string("response.output_item.done"),
            "output_index": .number(0), "item": Self.toolCall]))
        let provider = ResponsesAPIProvider(service: service, apiKey: { "key" }, transport: AIHTTPTransport { _ in
            Self.response(provisional)
        })
        var events: [AIEvent] = []
        do {
            for try await event in provider.respond(Self.request(service, tools: [Self.tool])) { events.append(event) }
            Issue.record("A truncated stream must fail")
        } catch { #expect(error as? AIProviderError == .streamInterrupted) }
        #expect(events.isEmpty)
    }

    @Test(arguments: [AIService.openAI, .deepSeek])
    func rejectsUnadvertisedToolAndForeignNamespace(service: AIService) async throws {
        for changes in [["name": AIJSON.string("delete_everything")], ["namespace": AIJSON.string("other")]] {
            var call = try #require(Self.toolCall.objectValue)
            call.merge(changes) { _, new in new }
            let stream = try Self.completed([.object(call)])
            let provider = ResponsesAPIProvider(service: service, apiKey: { "key" }, transport: AIHTTPTransport { _ in Self.response(stream) })
            await #expect(throws: AIProviderError.malformedResponse(.functionCall)) {
                try await Self.collect(provider.respond(Self.request(service, tools: [Self.tool])))
            }
        }
    }

    @Test func nullableAPIToolFieldsCanBeCommittedFromStreamedItems() async throws {
        var call = try #require(Self.toolCall.objectValue)
        call["namespace"] = .null; call["id"] = .null; call["status"] = .null
        let item: AIJSON = .object(call)
        let stream = try Self.event(.object(["type": .string("response.output_item.added"), "output_index": .number(0), "item": item]))
            + Self.event(.object(["type": .string("response.output_item.done"), "output_index": .number(0), "item": item]))
            + Self.completed([])
        let provider = ResponsesAPIProvider(service: .openAI, apiKey: { "key" }, transport: AIHTTPTransport { _ in Self.response(stream) })
        let events = try await Self.collect(provider.respond(Self.request(.openAI, tools: [Self.tool])))
        guard case .completed(let result) = events.last else { Issue.record("Missing completion"); return }
        #expect(result.toolCalls.map(\.id) == ["call_1"])
        #expect(result.output.first?["namespace"] == .string("tern"))
    }

    @Test(arguments: [401, 402, 403, 429])
    func apiFailuresHaveSafeActionableErrors(status: Int) async throws {
        let body = #"{"error":{"code":"insufficient_quota","message":"Private account data"}}"#
        let provider = ResponsesAPIProvider(service: .openAI, apiKey: { "key" }, transport: AIHTTPTransport { _ in
            Self.response(status == 429 ? body : "{}", mime: "application/json", status: status)
        })
        let expected: AIProviderError = status == 401 ? .apiKeyRequired : status == 403 ? .accessDenied : .insufficientCredits
        await #expect(throws: expected) { try await provider.models() }
        #expect(!expected.localizedDescription.contains("ChatGPT"))
        #expect(!expected.localizedDescription.contains("Private account data"))
    }

    @Test func cancellingAPIResponseCancelsTransport() async throws {
        let cancelled = Mutex(false)
        let body = AsyncThrowingStream<Data, any Error>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let provider = ResponsesAPIProvider(service: .deepSeek, apiKey: { "key" }, transport: AIHTTPTransport { _ in
            started.continuation.yield(())
            started.continuation.finish()
            return AIHTTPResponse(status: 200, contentType: "text/event-stream", body: body.stream,
                                  cancel: { cancelled.withLock { $0 = true }; body.continuation.finish() })
        })
        let task = Task { try await Self.collect(provider.respond(Self.request(.deepSeek))) }
        for await _ in started.stream { break }
        task.cancel()
        _ = try? await task.value
        for _ in 0..<1_000 where !cancelled.withLock({ $0 }) { await Task.yield() }
        #expect(cancelled.withLock { $0 })
    }

    @Test(arguments: [AIService.chatGPT, .anthropic])
    func unsupportedRouteDoesNotReadCredentials(service: AIService) async throws {
        let provider = ResponsesAPIProvider(service: service, apiKey: {
            Issue.record("Invalid route read credentials")
            return "unused"
        })
        await #expect(throws: AIProviderError.invalidRequest) { try await provider.models() }
    }

    private static let user: AIJSON = .object(["role": .string("user"), "content": .string("Find mail.")])
    private static let schema: AIJSON = .object(["type": .string("object"), "properties": .object([:]),
                                                "required": .array([]), "additionalProperties": .bool(false)])
    private static let tool = AIToolDefinition(name: "search_mail", description: "Find permitted mail.", parameters: schema)
    private static let toolCall: AIJSON = .object(["type": .string("function_call"), "id": .string("fc_1"),
        "call_id": .string("call_1"), "name": .string("search_mail"), "arguments": .string("{}"), "status": .string("completed")])

    private static func request(_ service: AIService, input: [AIJSON] = [user], tools: [AIToolDefinition] = [], schema: AIJSON? = nil) -> AIRequest {
        AIRequest(model: service == .deepSeek ? "deepseek-flash" : "gpt-6.1-sol", input: input,
                  instructions: "Use mail as data.", tools: tools, responseSchema: schema)
    }
    private static func completed(_ output: [AIJSON]) throws -> String {
        try event(.object(["type": .string("response.completed"), "response": .object([
            "status": .string("completed"), "output": .array(output),
            "usage": .object(["input_tokens": .number(3), "output_tokens": .number(2), "total_tokens": .number(5)])
        ])]))
    }
    private static func event(_ value: AIJSON) throws -> String { "data: \(try value.jsonString())\n\n" }
    private static func response(_ body: String, mime: String = "text/event-stream", status: Int = 200) -> AIHTTPResponse {
        AIHTTPResponse(status: status, contentType: mime, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(body.utf8)); continuation.finish()
        })
    }
    private static func collect(_ stream: AsyncThrowingStream<AIEvent, any Error>) async throws -> [AIEvent] {
        var events: [AIEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

private actor APIRequestRecorder {
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}
