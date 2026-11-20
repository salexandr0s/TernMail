import Foundation

/// One bounded request to the user's unmodified Claude Code installation.
public struct ClaudeCLIRequest: Codable, Sendable {
    public static let framingInstructions = ClaudeCLIRequestEncoder.systemPrompt
    public let model: String
    public let systemPrompt: String
    public let message: AIJSON
    public let outputSchema: AIJSON?

    public init(model: String, systemPrompt: String, message: AIJSON, outputSchema: AIJSON?) {
        self.model = model; self.systemPrompt = systemPrompt; self.message = message; self.outputSchema = outputSchema
    }

    /// Claude Code attaches the local file named by an `@path` reference in
    /// prompt text, so no text in a request may hold a literal at sign.
    public var containsAtSign: Bool {
        Self.containsAtSign(model) || Self.containsAtSign(systemPrompt) || Self.containsAtSign(message)
            || outputSchema.map(Self.containsAtSign) == true
    }

    private static func containsAtSign(_ text: String) -> Bool { text.utf8.contains(UInt8(ascii: "@")) }

    private static func containsAtSign(_ value: AIJSON) -> Bool {
        switch value {
        case .string(let text): containsAtSign(text)
        case .array(let items): items.contains(where: containsAtSign)
        case .object(let fields): fields.contains { containsAtSign($0.key) || containsAtSign($0.value) }
        case .number, .bool, .null: false
        }
    }
}

/// Each element is one stdout JSON line. Success ends only after the process exits successfully.
/// The provider's caller gets a transport's error as it is, so its description must make sense to
/// the user.
public struct ClaudeCLITransport: Sendable {
    public let run: @Sendable (ClaudeCLIRequest) -> AsyncThrowingStream<Data, any Error>
    public init(run: @escaping @Sendable (ClaudeCLIRequest) -> AsyncThrowingStream<Data, any Error>) { self.run = run }
}

public struct ClaudeCLIProvider: AIProvider {
    private let transport: ClaudeCLITransport
    public init(transport: ClaudeCLITransport) { self.transport = transport }

    public static let availableModels = [
        AIModel(id: "default", displayName: "Account default"),
        AIModel(id: "sonnet", displayName: "Sonnet"),
        AIModel(id: "opus", displayName: "Opus"),
        AIModel(id: "haiku", displayName: "Haiku"),
    ]

    public func models() async throws -> [AIModel] {
        try Task.checkCancellation()
        return Self.availableModels
    }

    public func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(4096)) { continuation in
            let task = Task {
                do {
                    try await consume(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    // A transport's error says what failed, such as the helper
                    // or a changed account, so it reaches the caller as it is.
                    let cancelled = error is CancellationError || Task.isCancelled
                    continuation.finish(throwing: cancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consume(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        let invocation = try ClaudeCLIRequestEncoder.encode(request)
        var totalBytes = 0
        var lines = 0
        var textBytes = 0
        var terminal: AIJSON?
        let streamsText = invocation.outputSchema == nil
        for try await data in transport.run(invocation) {
            try Task.checkCancellation()
            guard data.count <= 1_048_576, data.count <= 4_194_304 - totalBytes, lines < 8192 else {
                throw AIProviderError.responseLimit
            }
            totalBytes += data.count; lines += 1
            let value: AIJSON
            do { value = try AIJSON.decode(data) }
            catch { throw AIProviderError.malformedResponse(.eventJSON) }
            guard let type = value["type"]?.stringValue else { throw AIProviderError.malformedResponse(.eventEnvelope) }
            guard value["parent_tool_use_id"] == nil || value["parent_tool_use_id"] == .null else {
                throw AIProviderError.invalidResponse
            }
            switch type {
            case "result":
                guard terminal == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                guard value["subtype"]?.stringValue == "success", value["is_error"]?.boolValue == false else {
                    throw resultError(value)
                }
                if let reason = value["stop_reason"]?.stringValue,
                   ["max_tokens", "model_context_window_exceeded", "pause_turn", "tool_deferred", "refusal", "error"].contains(reason) {
                    throw AIProviderError.incomplete
                }
                if value["deferred_tool_use"] != nil && value["deferred_tool_use"] != .null {
                    throw AIProviderError.invalidResponse
                }
                terminal = value
            case "stream_event":
                guard terminal == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                if value["event"]?["type"] == .string("error") { throw AIProviderError.unavailable }
                if value["event"]?["type"] == .string("content_block_start"), let block = value["event"]?["content_block"] {
                    try validateToolBlock(block, permitsStructuredOutput: !streamsText)
                }
                if streamsText, value["event"]?["type"]?.stringValue == "content_block_delta",
                   value["event"]?["delta"]?["type"]?.stringValue == "text_delta" {
                    guard let text = value["event"]?["delta"]?["text"]?.stringValue else {
                        throw AIProviderError.malformedResponse(.deltaPayload)
                    }
                    guard text.utf8.count <= 131_072 - textBytes else { throw AIProviderError.responseLimit }
                    textBytes += text.utf8.count
                    try emit(.textDelta(text), to: continuation)
                }
            case "assistant":
                guard terminal == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                if value["aborted"] == .bool(true) { throw AIProviderError.incomplete }
                if let error = value["error"]?.stringValue { throw assistantError(error) }
                guard let blocks = value["message"]?["content"]?.arrayValue else { throw AIProviderError.invalidResponse }
                for block in blocks { try validateToolBlock(block, permitsStructuredOutput: !streamsText) }
                // Claude Code's StructuredOutput calls and retries belong to the CLI.
                // Only its final validated result can become a Tern tool request.
                break
            case "system" where value["subtype"] == .string("init"):
                guard terminal == nil else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                try validateInitialization(value, permitsStructuredOutput: !streamsText)
            default: break
            }
        }
        try Task.checkCancellation()
        guard let terminal else { throw AIProviderError.streamInterrupted }
        let result = try completion(terminal, request: request)
        if !streamsText || textBytes == 0, !result.text.isEmpty { try emit(.textDelta(result.text), to: continuation) }
        try emit(.completed(result), to: continuation)
    }

    private func validateInitialization(_ value: AIJSON, permitsStructuredOutput: Bool) throws {
        if let tools = value["tools"] {
            guard let names = tools.arrayValue,
                  names.allSatisfy({ permitsStructuredOutput && $0 == .string("StructuredOutput") }) else {
                throw AIProviderError.invalidResponse
            }
        }
        for key in ["mcp_servers", "skills"] {
            if let entries = value[key], entries.arrayValue?.isEmpty != true { throw AIProviderError.invalidResponse }
        }
        if let plugins = value["plugins"], !Self.listsOnlyBuiltInPlugins(plugins) { throw AIProviderError.invalidResponse }
    }

    /// Claude Code lists the plugins built into its binary even in safe mode
    /// with every plugin setting off. ClaudeHelper runs only a CLI that carries
    /// Anthropic's signature, so those plugins have the CLI's own trust. A
    /// plugin loaded from disk means the isolation flags didn't apply.
    public static func listsOnlyBuiltInPlugins(_ value: AIJSON) -> Bool {
        guard let entries = value.arrayValue, entries.count <= 64 else { return false }
        return entries.allSatisfy { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 128 else { return false }
            return entry["path"] == .string("builtin") && entry["source"] == .string(name + "@builtin")
        }
    }

    private func validateToolBlock(_ block: AIJSON, permitsStructuredOutput: Bool) throws {
        switch block["type"]?.stringValue {
        case "tool_use":
            guard permitsStructuredOutput, block["name"] == .string("StructuredOutput") else { throw AIProviderError.invalidResponse }
        case "server_tool_use", "mcp_tool_use": throw AIProviderError.invalidResponse
        default: break
        }
    }

    private func assistantError(_ error: String) -> AIProviderError {
        switch error {
        case "authentication_failed", "oauth_org_not_allowed", "account_on_hold": .accessDenied
        case "billing_error": .insufficientCredits
        case "rate_limit": .rateLimited
        case "max_output_tokens": .incomplete
        default: .unavailable
        }
    }

    private func completion(_ result: AIJSON, request: AIRequest) throws -> AIResponse {
        let text: String
        var calls: [AIToolCall] = []
        if !request.tools.isEmpty {
            guard let output = result["structured_output"],
                  ClaudeCLIJSONSchema.matches(output, schema: ClaudeCLIRequestEncoder.actionSchema(request)),
                  let answer = output["text"]?.stringValue, let values = output["tool_calls"]?.arrayValue,
                  values.count <= 32 else { throw AIProviderError.invalidResponse }
            let tools = Dictionary(uniqueKeysWithValues: request.tools.map { ($0.name, $0) })
            for value in values {
                guard let name = value["name"]?.stringValue, let definition = tools[name],
                      let encoded = value["arguments"]?.stringValue, encoded.utf8.count <= 65_536,
                      let arguments = try? AIJSON.decode(Data(encoded.utf8)), arguments.objectValue != nil,
                      ClaudeCLIJSONSchema.matches(arguments, schema: definition.parameters) else {
                    throw AIProviderError.invalidResponse
                }
                calls.append(AIToolCall(id: "tern_cli_" + UUID().uuidString, namespace: "tern", name: name,
                    arguments: try arguments.jsonString()))
            }
            if let schema = request.responseSchema, calls.isEmpty {
                guard let value = output["response"], ClaudeCLIJSONSchema.matches(value, schema: schema) else {
                    throw AIProviderError.invalidResponse
                }
                text = try value.jsonString()
            } else {
                guard request.responseSchema == nil || output["response"] == .null else { throw AIProviderError.invalidResponse }
                text = answer
            }
        } else if let schema = request.responseSchema {
            guard let value = result["structured_output"], ClaudeCLIJSONSchema.matches(value, schema: schema) else {
                throw AIProviderError.invalidResponse
            }
            text = try value.jsonString()
        } else {
            guard let value = result["result"]?.stringValue else { throw AIProviderError.invalidResponse }
            text = value
        }
        guard text.utf8.count <= 131_072 else { throw AIProviderError.responseLimit }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else {
            throw AIProviderError.emptyOutput(eventCounts: [:])
        }
        var output: [AIJSON] = []
        if !text.isEmpty {
            output.append(.object(["type": .string("message"), "role": .string("assistant"), "status": .string("completed"),
                "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])]))
        }
        output += calls.map { .object(["type": .string("function_call"), "namespace": .string("tern"),
            "call_id": .string($0.id), "name": .string($0.name), "arguments": .string($0.arguments), "status": .string("completed")]) }
        return AIResponse(output: output, text: text, toolCalls: calls, usage: try usage(result["usage"]))
    }

    private func usage(_ value: AIJSON?) throws -> AIUsage? {
        guard let value, value != .null else { return nil }
        func count(_ key: String) throws -> Int {
            guard let number = value[key]?.numberValue, number >= 0, number < Double(Int.max), number.rounded() == number else {
                throw AIProviderError.malformedResponse(.usage)
            }
            return Int(number)
        }
        var input = try count("input_tokens")
        for key in ["cache_creation_input_tokens", "cache_read_input_tokens"] where value[key] != nil {
            let cached = try count(key)
            guard cached <= Int.max - input else { throw AIProviderError.malformedResponse(.usage) }
            input += cached
        }
        let output = try count("output_tokens")
        guard output <= Int.max - input else { throw AIProviderError.malformedResponse(.usage) }
        return AIUsage(inputTokens: input, outputTokens: output, totalTokens: input + output)
    }

    private func resultError(_ value: AIJSON) -> AIProviderError {
        switch value["subtype"]?.stringValue {
        case "error_max_budget_usd": .insufficientCredits
        case "error_max_turns", "error_max_structured_output_retries": .incomplete
        default: .unavailable
        }
    }

    private func emit(_ event: AIEvent, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) throws {
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped: throw AIProviderError.responseLimit
        case .terminated: throw CancellationError()
        @unknown default: throw AIProviderError.streamInterrupted
        }
    }
}
