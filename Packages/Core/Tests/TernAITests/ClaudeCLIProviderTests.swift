import Foundation
import Testing
@testable import TernAI

@Suite(.timeLimit(.minutes(1))) struct ClaudeCLIProviderTests {
    @Test func streamsPlainAnswerAndCommitsCanonicalOutputAfterSuccess() async throws {
        let provider = Self.provider([
            Self.initialization(), Self.delta("Grüße"),
            Self.success(text: "Grüße", usage: .object(["input_tokens": .number(3), "output_tokens": .number(4)])),
        ])
        let events = try await Self.collect(provider.respond(Self.request()))
        #expect(events.first == .textDelta("Grüße"))
        #expect(events.count == 2)
        let completed = try Self.completed(events)
        #expect(completed.text == "Grüße")
        #expect(completed.usage == AIUsage(inputTokens: 3, outputTokens: 4, totalTokens: 7))
        #expect(completed.output.first?["role"] == .string("assistant"))
        #expect(try await provider.models().map(\.id) == ["default", "sonnet", "opus", "haiku"])
    }

    @Test func returnsValidatedToolRequestsAndReplaysResultsInNextInvocation() async throws {
        let capture = CLIRequestCapture()
        let provider = ClaudeCLIProvider(transport: ClaudeCLITransport { request in
            AsyncThrowingStream { continuation in
                let task = Task {
                    let index = await capture.append(request)
                    let result = index == 0 ? Self.success(output: Self.actionOutput()) : Self.success(text: "Found it.")
                    do {
                        // A StructuredOutput retry or narration is never a Tern action.
                        continuation.yield(try Self.delta("Unvalidated planning text").encoded())
                        continuation.yield(try result.encoded())
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
        let first = try Self.completed(await Self.collect(provider.respond(Self.request(tools: [Self.searchTool]))))
        #expect(first.text == "Checking mail.")
        let call = try #require(first.toolCalls.first)
        #expect(call.namespace == "tern")
        #expect(call.name == "search_mail")
        #expect(try AIJSON.decode(Data(call.arguments.utf8)) == .object(["query": .string("invoice"), "limit": .number(3)]))
        let input = Self.request().input + first.output + [.object([
            "type": .string("function_call_output"), "call_id": .string(call.id), "output": .string("{\"found\":true}")
        ])]
        _ = try await Self.collect(provider.respond(Self.request(input: input)))
        let requests = await capture.requests
        #expect(requests.count == 2)
        #expect(requests[0].outputSchema != nil)
        #expect(requests[1].outputSchema == nil)
        let envelope = try Self.envelope(requests[1])
        #expect(envelope["available_tools"] == .array([]))
        let history = try #require(envelope["conversation_history"]?.arrayValue)
        #expect(history.last?["type"] == .string("function_call_output"))
        #expect(history.last?["call_id"] == .string(call.id))
        #expect(history.last?["output"] == .string("{\"found\":true}"))
    }

    @Test func sendsImagesAndPrivateInstructionsOnlyThroughTheUserMessage() async throws {
        let capture = CLIRequestCapture()
        let provider = ClaudeCLIProvider(transport: ClaudeCLITransport { request in
            AsyncThrowingStream { continuation in
                Task {
                    _ = await capture.append(request)
                    do { continuation.yield(try Self.success(text: "Image received.").encoded()); continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                }
            }
        })
        let image: AIJSON = .object(["role": .string("user"), "content": .array([
            .object(["type": .string("input_text"), "text": .string("Describe the image.")]),
            .object(["type": .string("input_image"), "image_url": .string("data:image/png;base64,YQ==")]),
        ])])
        _ = try await Self.collect(provider.respond(AIRequest(model: "sonnet", input: [image], instructions: "Private account scope")))
        let request = try #require(await capture.requests.first)
        #expect(request.systemPrompt == ClaudeCLIRequest.framingInstructions)
        #expect(!request.systemPrompt.contains("Private account scope"))
        #expect(request.message["type"] == .string("user"))
        let content = try #require(request.message["message"]?["content"]?.arrayValue)
        #expect(content.count == 3)
        #expect(content[2]["source"] == .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string("YQ==")]))
        let envelope = try Self.envelope(request)
        #expect(envelope["application_instructions"] == .string("Private account scope"))
        #expect(!((try envelope.jsonString()).contains("YQ==")))
        let roundTrip = try JSONDecoder().decode(ClaudeCLIRequest.self, from: JSONEncoder().encode(request))
        #expect(roundTrip.message == request.message)
        #expect(roundTrip.systemPrompt == request.systemPrompt)
    }

    @Test func schemaOnlyAnalysisUsesValidatedStructuredOutput() async throws {
        let result: AIJSON = .object(["count": .number(2)])
        let provider = Self.provider([Self.initialization(structured: true), Self.delta("Internal narration"),
            .object(["type": .string("assistant"), "message": .object(["content": .array([
                .object(["type": .string("tool_use"), "name": .string("StructuredOutput"), "input": .object([:])])
            ])])]), Self.success(output: result)])
        let events = try await Self.collect(provider.respond(Self.request(schema: Self.countSchema)))
        #expect(events == [.textDelta("{\"count\":2}"), .completed(AIResponse(output: [Self.message("{\"count\":2}")], text: "{\"count\":2}", toolCalls: []))])
    }

    @Test(arguments: ["unknown_tool", "extra_argument", "missing_argument", "out_of_range", "extra_envelope", "invalid_json", "non_object"])
    func rejectsInvalidActions(failure: String) async throws {
        var arguments: [String: AIJSON] = ["query": .string("invoice"), "limit": .number(3)]
        if failure == "extra_argument" { arguments["send"] = .bool(true) }
        if failure == "missing_argument" { arguments.removeValue(forKey: "query") }
        if failure == "out_of_range" { arguments["limit"] = .number(99) }
        let encodedArguments = failure == "invalid_json" ? "{" : failure == "non_object" ? "[]" : try AIJSON.object(arguments).jsonString()
        var output: [String: AIJSON] = ["text": .string(""), "tool_calls": .array([.object([
            "name": .string(failure == "unknown_tool" ? "send_mail" : "search_mail"), "arguments": .string(encodedArguments)
        ])])]
        if failure == "extra_envelope" { output["permission"] = .bool(true) }
        let provider = Self.provider([Self.success(output: .object(output))])
        await #expect(throws: AIProviderError.invalidResponse) {
            try await Self.collect(provider.respond(Self.request(tools: [Self.searchTool])))
        }
    }

    @Test(arguments: ["missing_output", "wrong_type", "out_of_range"])
    func rejectsInvalidStructuredResults(failure: String) async throws {
        let value: AIJSON? = failure == "missing_output" ? nil : .object([
            "count": failure == "wrong_type" ? .string("two") : .number(99)
        ])
        let provider = Self.provider([Self.success(output: value)])
        await #expect(throws: AIProviderError.invalidResponse) {
            try await Self.collect(provider.respond(Self.request(schema: Self.countSchema)))
        }
    }

    @Test(arguments: ["truncated", "result_error", "duplicate_result", "process_failure"])
    func neverCommitsToolsWithoutOneSuccessfulTerminalAndProcessExit(failure: String) async throws {
        var lines: [AIJSON] = []
        if failure == "result_error" {
            lines = [.object(["type": .string("result"), "subtype": .string("error_max_turns"), "is_error": .bool(true),
                "errors": .array([.string("Private upstream details")]), "structured_output": Self.actionOutput()])]
        } else if failure != "truncated" { lines = [Self.success(output: Self.actionOutput())] }
        if failure == "duplicate_result" { lines += lines }
        let provider = Self.provider(lines, failure: failure == "process_failure" ? AIProviderError.unavailable : nil)
        var committed = false
        do {
            for try await event in provider.respond(Self.request(tools: [Self.searchTool])) {
                if case .completed = event { committed = true }
            }
            Issue.record("Expected a rejected CLI run")
        } catch { #expect(!error.localizedDescription.contains("Private upstream details")) }
        #expect(!committed)
    }

    @Test func boundedInputAndUnsupportedSchemasDoNotLaunchAProcess() async throws {
        let provider = ClaudeCLIProvider(transport: ClaudeCLITransport { _ in
            Issue.record("Invalid request reached the process transport")
            return AsyncThrowingStream { $0.finish() }
        })
        let large = Self.request(input: [.object(["role": .string("user"), "content": .string(String(repeating: "x", count: 524_289))])])
        await #expect(throws: AIProviderError.invalidRequest) { try await Self.collect(provider.respond(large)) }
        await #expect(throws: AIProviderError.invalidRequest) {
            try await Self.collect(provider.respond(Self.request(schema: .object(["$ref": .string("https://untrusted.invalid/schema")]))))
        }
        // The schema is also passed as a CLI argument, where escaping cannot apply.
        await #expect(throws: AIProviderError.invalidRequest) {
            try await Self.collect(provider.respond(Self.request(schema: .object(["type": .string("object"), "description": .string("@/etc/hosts")]))))
        }
    }

    @Test func rejectsOversizedFinalText() async throws {
        let provider = Self.provider([Self.success(text: String(repeating: "x", count: 131_073))])
        await #expect(throws: AIProviderError.responseLimit) { try await Self.collect(provider.respond(Self.request())) }
    }

    @Test(arguments: ["tool", "mcp_servers", "plugins", "skills", "native_stream_tool", "native_assistant_tool", "subagent", "assistant_error", "aborted", "max_tokens", "refusal", "sse_error"])
    func rejectsUnexpectedCLICapabilitiesAndIncompleteOutput(failure: String) async throws {
        let unsafe: AIJSON
        switch failure {
        case "tool":
            unsafe = .object(["type": .string("system"), "subtype": .string("init"), "tools": .array([.string("Bash")])])
        case "mcp_servers", "skills":
            unsafe = .object(["type": .string("system"), "subtype": .string("init"), failure: .array([.string("unexpected")])])
        case "plugins":
            // The source names the builtin marketplace, but the plugin was loaded from disk.
            unsafe = .object(["type": .string("system"), "subtype": .string("init"), "plugins": .array([.object([
                "name": .string("example-plugin"), "path": .string("/tmp/example-plugin"), "source": .string("example-plugin@builtin"),
            ])])])
        case "native_stream_tool":
            unsafe = .object(["type": .string("stream_event"), "event": .object(["type": .string("content_block_start"),
                "content_block": .object(["type": .string("tool_use"), "name": .string("Bash")])])])
        case "native_assistant_tool":
            unsafe = .object(["type": .string("assistant"), "message": .object(["content": .array([
                .object(["type": .string("tool_use"), "name": .string("Bash")])
            ])])])
        case "subagent": unsafe = Self.delta("Unexpected subagent", parent: "child")
        case "assistant_error": unsafe = .object(["type": .string("assistant"), "error": .string("rate_limit")])
        case "aborted": unsafe = .object(["type": .string("assistant"), "aborted": .bool(true)])
        case "sse_error": unsafe = .object(["type": .string("stream_event"), "event": .object(["type": .string("error")])])
        default:
            var fields = try #require(Self.success(output: Self.actionOutput()).objectValue)
            fields["stop_reason"] = .string(failure)
            unsafe = .object(fields)
        }
        let provider = Self.provider([unsafe, Self.success(output: Self.actionOutput())])
        var committed = false
        do {
            for try await event in provider.respond(Self.request(tools: [Self.searchTool])) {
                if case .completed = event { committed = true }
            }
            Issue.record("Unexpected CLI capabilities or incomplete output were accepted")
        } catch { #expect(error is AIProviderError) }
        #expect(!committed)
    }

    @Test func toolOutputSchemaDoesNotGrowWithParameterSchemas() throws {
        let tools = (0..<16).map { index in
            AIToolDefinition(name: "tool_\(index)", description: "Tool description.", parameters: Self.searchTool.parameters)
        }
        let invocation = try ClaudeCLIRequestEncoder.encode(Self.request(tools: tools))
        let schema = try #require(invocation.outputSchema)
        let items = schema["properties"]?["tool_calls"]?["items"]
        #expect(items?["properties"]?["name"]?["enum"]?.arrayValue?.count == 16)
        #expect(items?["properties"]?["arguments"]?["type"] == .string("string"))
        #expect(!(try schema.jsonString()).contains("query"))
        #expect(try Self.envelope(invocation)["available_tools"]?.arrayValue?.count == 16)
    }

    @Test func escapesEveryAtSignSoTheCLICannotAttachLocalFiles() throws {
        let path = "See @/Users/person/.aws/credentials"
        let combining = "@\u{301}/etc/hosts"
        let arguments = #"{"query":"from:pat@example.invalid","limit":1}"#
        let output = #"{"from":"@~/.ssh/id_ed25519"}"#
        let tool = AIToolDefinition(name: "search_mail", description: "Find mail from @sender.", parameters: Self.searchTool.parameters)
        let invocation = try ClaudeCLIRequestEncoder.encode(AIRequest(model: "sonnet", input: [
            .object(["role": .string("user"), "content": .string(path)]),
            .object(["type": .string("function_call"), "namespace": .string("tern"), "call_id": .string("call_1"),
                "name": .string("search_mail"), "arguments": .string(arguments)]),
            .object(["type": .string("function_call_output"), "call_id": .string("call_1"), "output": .string(output)]),
            .object(["role": .string("assistant"), "content": .array([.object(["type": .string("output_text"), "text": .string("Ask pat@example.invalid.")])])]),
            .object(["role": .string("user"), "content": .array([.object(["type": .string("input_text"), "text": .string(combining)])])]),
        ], instructions: "The mailbox is me@example.invalid.", tools: [tool]))
        #expect(!invocation.containsAtSign)
        #expect(!(try JSONEncoder().encode(invocation)).contains(UInt8(ascii: "@")))
        let envelope = try Self.envelope(invocation)
        #expect(envelope["application_instructions"] == .string("The mailbox is me@example.invalid."))
        #expect(envelope["available_tools"]?.arrayValue?.first?["description"] == .string("Find mail from @sender."))
        let history = try #require(envelope["conversation_history"]?.arrayValue)
        #expect(history.count == 5)
        #expect(history[0]["content"] == .string(path))
        #expect(history[1]["arguments"] == (try AIJSON.decode(Data(arguments.utf8))))
        #expect(history[2]["output"] == .string(output))
        #expect(history[3]["content"]?.arrayValue?.first?["text"] == .string("Ask pat@example.invalid."))
        #expect(history[4]["content"]?.arrayValue?.first?["text"] == .string(combining))
    }

    @Test func cancellationTerminatesTheOwnedTransport() async throws {
        let started = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); stopped.continuation.finish() }
        let provider = ClaudeCLIProvider(transport: ClaudeCLITransport { _ in
            AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in stopped.continuation.yield(()) }
                started.continuation.yield(())
            }
        })
        let task = Task { try await Self.collect(provider.respond(Self.request())) }
        defer { task.cancel() }
        var start = started.stream.makeAsyncIterator()
        #expect(await start.next() != nil)
        task.cancel()
        _ = await task.result
        var stop = stopped.stream.makeAsyncIterator()
        #expect(await stop.next() != nil)
    }

    private static let countSchema: AIJSON = .object([
        "type": .string("object"), "properties": .object(["count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(3)])]),
        "required": .array([.string("count")]), "additionalProperties": .bool(false),
    ])

    private static let searchTool = AIToolDefinition(name: "search_mail", description: "Find mail.", parameters: .object([
        "type": .string("object"), "properties": .object([
            "query": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(5)]),
        ]), "required": .array([.string("query"), .string("limit")]), "additionalProperties": .bool(false),
    ]))

    private static func request(input: [AIJSON]? = nil, tools: [AIToolDefinition] = [], schema: AIJSON? = nil) -> AIRequest {
        AIRequest(model: "sonnet", input: input ?? [.object(["role": .string("user"), "content": .string("Find invoices.")])],
            instructions: "Use only allowed mail.", tools: tools, responseSchema: schema)
    }

    private static func actionOutput() -> AIJSON {
        .object(["text": .string("Checking mail."), "tool_calls": .array([.object([
            "name": .string("search_mail"), "arguments": .string("{\"query\":\"invoice\",\"limit\":3}")
        ])])])
    }

    /// Claude Code lists the plugins built into it even in safe mode.
    private static func initialization(structured: Bool = false) -> AIJSON {
        .object(["type": .string("system"), "subtype": .string("init"),
            "tools": .array(structured ? [.string("StructuredOutput")] : []), "mcp_servers": .array([]),
            "plugins": .array([.object(["name": .string("cc-plugin-privacy"), "path": .string("builtin"),
                "source": .string("cc-plugin-privacy@builtin")])]),
            "skills": .array([])])
    }

    private static func success(text: String = "", output: AIJSON? = nil, usage: AIJSON? = nil) -> AIJSON {
        var fields: [String: AIJSON] = ["type": .string("result"), "subtype": .string("success"), "is_error": .bool(false), "result": .string(text)]
        fields["structured_output"] = output; fields["usage"] = usage
        return .object(fields)
    }

    private static func delta(_ text: String, parent: String? = nil) -> AIJSON {
        .object(["type": .string("stream_event"), "parent_tool_use_id": parent.map(AIJSON.string) ?? .null,
            "event": .object(["type": .string("content_block_delta"), "delta": .object(["type": .string("text_delta"), "text": .string(text)])])])
    }

    private static func message(_ text: String) -> AIJSON {
        .object(["type": .string("message"), "role": .string("assistant"), "status": .string("completed"),
            "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])
    }

    private static func provider(_ lines: [AIJSON], failure: AIProviderError? = nil) -> ClaudeCLIProvider {
        ClaudeCLIProvider(transport: ClaudeCLITransport { _ in
            AsyncThrowingStream { continuation in
                do {
                    for line in lines { continuation.yield(try line.encoded()) }
                    continuation.finish(throwing: failure)
                } catch { continuation.finish(throwing: error) }
            }
        })
    }

    private static func envelope(_ invocation: ClaudeCLIRequest) throws -> AIJSON {
        try AIJSON.decode(Data(try #require(invocation.message["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue).utf8))
    }

    private static func collect(_ stream: AsyncThrowingStream<AIEvent, any Error>) async throws -> [AIEvent] {
        var events: [AIEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private static func completed(_ events: [AIEvent]) throws -> AIResponse {
        guard case .completed(let response) = try #require(events.last) else { throw AIProviderError.streamInterrupted }
        return response
    }
}

private actor CLIRequestCapture {
    private(set) var requests: [ClaudeCLIRequest] = []
    func append(_ request: ClaudeCLIRequest) -> Int {
        let index = requests.count
        requests.append(request)
        return index
    }
}
