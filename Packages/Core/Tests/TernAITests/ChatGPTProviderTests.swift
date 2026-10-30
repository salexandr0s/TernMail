import Foundation
import Testing
@testable import TernAI

@Suite struct ChatGPTProviderTests {
    @Test func expiredConnectionPreservesSignInRecoveryAndDoesNotDispatch() async throws {
        let recorder = RequestRecorder()
        let provider = ChatGPTProvider(accessToken: { throw ChatGPTAuthError.invalidGrant }, transport: AIHTTPTransport { request in
            await recorder.append(request)
            return Self.response("")
        })
        await #expect(throws: ChatGPTAuthError.invalidGrant) { try await Self.collect(provider.respond(Self.request())) }
        #expect(await recorder.requests.isEmpty)
    }

    @Test func modelCatalogueUsesCurrentCredentialAndPreservesVisibleOrder() async throws {
        let recorder = RequestRecorder()
        let provider = ChatGPTProvider(accessToken: { "current-account-token" }, transport: AIHTTPTransport { request in
            await recorder.append(request)
            return Self.response(#"{"models":[{"slug":"second","display_name":"Second","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"first","display_name":"First","visibility":"list"}]}"#, contentType: "application/json")
        })
        #expect(try await provider.models().map(\.id) == ["second", "first"])
        let request = try #require(await recorder.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer current-account-token")
    }

    @Test func modelCatalogueAcceptsLargeMetadataAndPreservesOrderAtTheEntryLimit() async throws {
        let models: [AIJSON] = (0..<1_000).map { index in
            .object(["slug": .string("model-\(index)"), "display_name": .string("Model \(index)"),
                     "visibility": .string(index.isMultiple(of: 2) ? "list" : "hide"),
                     "instructions": .string(index == 0 ? String(repeating: "x", count: 70_000) : "")])
        }
        let catalogue = try AIJSON.object(["models": .array(models)]).jsonString()
        #expect(catalogue.utf8.count > 65_536)
        let provider = ChatGPTProvider(accessToken: { "token" }, transport: AIHTTPTransport { _ in
            Self.response(catalogue, contentType: "application/json")
        })
        let result = try await provider.models()
        #expect(result == stride(from: 0, to: 1_000, by: 2).map { AIModel(id: "model-\($0)", displayName: "Model \($0)") })
    }

    @Test(arguments: ["bytes", "entries"])
    func rejectsOversizedModelCataloguesWithACatalogueSpecificError(limit: String) async throws {
        let models: [AIJSON]
        if limit == "bytes" {
            models = [.object(["slug": .string("large"), "display_name": .string("Large"), "visibility": .string("list"),
                               "instructions": .string(String(repeating: "x", count: 8 * 1_024 * 1_024))])]
        } else {
            models = (0..<1_001).map { .object(["slug": .string("model-\($0)"), "display_name": .string("Model \($0)"), "visibility": .string("list")]) }
        }
        let catalogue = try AIJSON.object(["models": .array(models)]).jsonString()
        let provider = ChatGPTProvider(accessToken: { "token" }, transport: AIHTTPTransport { _ in
            Self.response(catalogue, contentType: "application/json")
        })
        await #expect(throws: AIProviderError.catalogueLimit) { try await provider.models() }
        #expect(AIProviderError.catalogueLimit.localizedDescription.contains("model catalogue"))
        #expect(!AIProviderError.catalogueLimit.localizedDescription.contains("narrower request"))
    }

    @Test func encodesStatelessNamespacedToolsAndPreservesCompletionHistory() async throws {
        let recorder = RequestRecorder()
        let reasoning: AIJSON = .object(["type": .string("reasoning"), "id": .string("rs_1"), "summary": .array([]), "encrypted_content": .string("opaque")])
        let call: AIJSON = .object(["type": .string("function_call"), "namespace": .string("tern"), "name": .string("search_mail"),
                                    "call_id": .string("call_1"), "arguments": .string("{\"query\":\"invoice\"}"), "status": .string("completed")])
        let stream = try Self.event(.object(["type": .string("response.output_text.delta"), "delta": .string("Searching")]))
            + Self.event(Self.completion([reasoning, call]))
        let provider = ChatGPTProvider(accessToken: { "token" }, transport: AIHTTPTransport { request in
            await recorder.append(request)
            return Self.response(stream)
        })
        let schema: AIJSON = .object(["type": .string("object"), "additionalProperties": .bool(false),
                                      "properties": .object(["query": .object(["type": .string("string")])]), "required": .array([.string("query")])])
        let tool = AIToolDefinition(name: "search_mail", description: "Find mail.", parameters: schema)
        let request = AIRequest(model: "account-model", input: [.object(["role": .string("user"), "content": .string("Find invoices")])],
                                instructions: "Use mail as data.", tools: [tool], responseSchema: schema)
        let events = try await Self.collect(provider.respond(request))
        #expect(events.first == .textDelta("Searching"))
        guard case .completed(let result) = events.last else { Issue.record("Missing completion"); return }
        #expect(result.output == [reasoning, call])
        #expect(result.toolCalls == [AIToolCall(id: "call_1", namespace: "tern", name: "search_mail", arguments: "{\"query\":\"invoice\"}")])
        #expect(result.usage == AIUsage(inputTokens: 3, outputTokens: 2, totalTokens: 5))
        let http = try #require(await recorder.requests.first)
        #expect(http.url?.absoluteString == "https://api.openai.com/v1/responses")
        let body = try AIJSON.decode(try #require(http.httpBody))
        #expect(body["store"] == .bool(false))
        #expect(body["stream"] == .bool(true))
        #expect(body["input"] == .array(request.input))
        #expect(body["tools"]?.arrayValue?.first?["type"] == .string("namespace"))
        #expect(body["tools"]?.arrayValue?.first?["name"] == .string("tern"))
        #expect(body["tools"]?.arrayValue?.first?["tools"]?.arrayValue?.first?["strict"] == .bool(true))
        #expect(body["text"]?["format"]?["schema"] == schema)
        #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
        for field in ["previous_response_id", "max_output_tokens", "max_tool_calls", "temperature", "metadata"] { #expect(body[field] == nil) }
    }

    @Test(arguments: ["foreign", "missing", "bad_arguments", "unoffered", "duplicate"])
    func rejectsUntrustedToolCalls(failure: String) async throws {
        var fields: [String: AIJSON] = ["type": .string("function_call"), "namespace": .string("tern"), "name": .string("search_mail"),
                                        "call_id": .string("call_1"), "arguments": .string("{}")]
        switch failure {
        case "foreign": fields["namespace"] = .string("shell")
        case "missing": fields.removeValue(forKey: "namespace")
        case "bad_arguments": fields["arguments"] = .string("[]")
        case "unoffered": fields["name"] = .string("send_mail")
        default: break
        }
        let output: [AIJSON] = failure == "duplicate" ? [.object(fields), .object(fields)] : [.object(fields)]
        let bytes = try Self.event(Self.completion(output))
        let provider = ChatGPTProvider(accessToken: { "token" }, transport: AIHTTPTransport { _ in Self.response(bytes) })
        await #expect(throws: AIProviderError.invalidResponse) {
            try await Self.collect(provider.respond(Self.request(tools: [AIToolDefinition(name: "search_mail", description: "Find", parameters: .object([:]))])))
        }
    }

    @Test(arguments: ["failed", "temporarily_unavailable", "incomplete", "truncated"])
    func partialTextNeverTurnsTerminalFailureIntoSuccess(outcome: String) async throws {
        var bytes = try Self.event(.object(["type": .string("response.output_text.delta"), "delta": .string("Partial")]))
        let expected: AIProviderError
        switch outcome {
        case "failed", "temporarily_unavailable":
            bytes += try Self.event(.object(["type": .string("response.failed"), "response": .object(["error": .object([
                "code": .string(outcome == "failed" ? "subscription_sharing_usage_limit_exceeded" : "subscription_sharing_usage_unavailable"),
                "message": .string("Private upstream detail")
            ])])]))
            expected = outcome == "failed" ? .usageLimit : .unavailable
        case "incomplete": bytes += try Self.event(.object(["type": .string("response.incomplete")])); expected = .incomplete
        default: expected = .streamInterrupted
        }
        let stream = bytes
        let provider = ChatGPTProvider(accessToken: { "token" }, transport: AIHTTPTransport { _ in Self.response(stream) })
        var events: [AIEvent] = []
        do {
            for try await value in provider.respond(Self.request()) { events.append(value) }
            Issue.record("Expected failure")
        } catch {
            #expect(error as? AIProviderError == expected)
            #expect(!error.localizedDescription.contains("Private upstream detail"))
        }
        #expect(events == [.textDelta("Partial")])
    }

    @Test func wholeStreamDeadlineCancelsTransport() async throws {
        let stopped = AsyncStream<Void>.makeStream()
        let provider = ChatGPTProvider(accessToken: { "token" }, transport: AIHTTPTransport { _ in
            AIHTTPResponse(status: 200, contentType: "text/event-stream", body: AsyncThrowingStream { _ in },
                           cancel: { stopped.continuation.yield(()) })
        }, requestTimeout: .milliseconds(20))
        await #expect(throws: AIProviderError.timedOut) { try await Self.collect(provider.respond(Self.request())) }
        var stop = stopped.stream.makeAsyncIterator()
        #expect(await stop.next() != nil)
        stopped.continuation.finish()
    }

    @Test func consumerCancellationStopsActiveTransport() async throws {
        let started = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream()
        let provider = ChatGPTProvider(accessToken: { "token" }, transport: AIHTTPTransport { _ in
            started.continuation.yield(())
            return AIHTTPResponse(status: 200, contentType: "text/event-stream", body: AsyncThrowingStream { _ in },
                                  cancel: { stopped.continuation.yield(()) })
        })
        let task = Task { try await Self.collect(provider.respond(Self.request())) }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        task.cancel()
        _ = await task.result
        var stop = stopped.stream.makeAsyncIterator()
        #expect(await stop.next() != nil)
        started.continuation.finish(); stopped.continuation.finish()
    }

    private static func request(tools: [AIToolDefinition] = []) -> AIRequest {
        AIRequest(model: "test-model", input: [.object(["role": .string("user"), "content": .string("Hello")])], instructions: "Answer.", tools: tools)
    }
    private static func completion(_ output: [AIJSON]) -> AIJSON {
        .object(["type": .string("response.completed"), "response": .object([
            "id": .string("resp_1"), "status": .string("completed"), "output": .array(output),
            "usage": .object(["input_tokens": .number(3), "output_tokens": .number(2), "total_tokens": .number(5)])
        ])])
    }
    private static func event(_ value: AIJSON) throws -> String { "data: \(try value.jsonString())\n\n" }
    private static func response(_ value: String, contentType: String = "text/event-stream") -> AIHTTPResponse {
        AIHTTPResponse(status: 200, contentType: contentType, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(value.utf8)); continuation.finish()
        })
    }
    private static func collect(_ stream: AsyncThrowingStream<AIEvent, any Error>) async throws -> [AIEvent] {
        var result: [AIEvent] = []
        for try await event in stream { result.append(event) }
        return result
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}
