import Foundation

/// Direct ChatGPT-plan inference. Credentials come from Tern's connection manager.
public struct ChatGPTProvider: AIProvider {
    private let accessToken: @Sendable () async throws -> String
    private let transport: AIHTTPTransport
    private let requestTimeout: Duration

    public init(accessToken: @escaping @Sendable () async throws -> String,
                transport: AIHTTPTransport = .live, requestTimeout: Duration = .seconds(120)) {
        self.accessToken = accessToken; self.transport = transport; self.requestTimeout = requestTimeout
    }

    public func models() async throws -> [AIModel] {
        do {
            return try await deadline {
                let request = try await authorizedRequest(path: "models", method: "GET")
                let response = try await transport.send(request)
                defer { response.cancel() }
                try await checkStatus(response)
                // Catalogue entries include model instructions and other metadata
                // that are much larger than the two fields used by the picker.
                let value = try AIJSON.decode(try await collect(response.body, limit: 8 * 1_024 * 1_024))
                guard let models = value["models"]?.arrayValue else { throw AIProviderError.invalidResponse }
                guard models.count <= 1_000 else { throw AIProviderError.catalogueLimit }
                var result: [AIModel] = []
                var seen: Set<String> = []
                for model in models {
                    guard let visibility = model["visibility"]?.stringValue else { throw AIProviderError.invalidResponse }
                    guard visibility == "list" else { continue }
                    guard let id = model["slug"]?.stringValue, identifier(id),
                          let name = model["display_name"]?.stringValue, !name.isEmpty, name.utf8.count <= 256,
                          seen.insert(id).inserted else { throw AIProviderError.invalidResponse }
                    result.append(AIModel(id: id, displayName: name))
                }
                return result
            }
        } catch {
            let failure = sanitized(error)
            if failure as? AIProviderError == .responseLimit { throw AIProviderError.catalogueLimit }
            throw failure
        }
    }

    public func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(4096)) { continuation in
            let task = Task {
                do {
                    try await deadline { try await consume(request, continuation: continuation) }
                    continuation.finish()
                } catch { continuation.finish(throwing: sanitized(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consume(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        let payload = try requestBody(request)
        var http = try await authorizedRequest(path: "responses", method: "POST")
        http.httpBody = payload
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let response = try await transport.send(http)
        defer { response.cancel() }
        try await checkStatus(response)
        if let mime = response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), mime != "text/event-stream" {
            throw AIProviderError.malformedResponse(.contentType)
        }
        var decoder = SSEDecoder()
        var textBytes = 0
        var streamedOutput = StreamedOutput()
        var eventCounts: [String: Int] = [:]
        for try await chunk in response.body {
            try Task.checkCancellation()
            let events: [SSEEvent]
            do { events = try decoder.append(chunk) }
            catch AIProviderError.invalidResponse { throw AIProviderError.malformedResponse(.eventEncoding) }
            for event in events {
                guard event.data != "[DONE]" else { throw AIProviderError.streamInterrupted }
                let value: AIJSON
                do { value = try AIJSON.decode(Data(event.data.utf8)) }
                catch { throw AIProviderError.malformedResponse(.eventJSON) }
                guard let type = value["type"]?.stringValue,
                      event.name == "message" || event.name == type else { throw AIProviderError.malformedResponse(.eventEnvelope) }
                let eventType = (type.hasPrefix("response.") || type == "error") && diagnosticIdentifier(type) != nil ? type : "other"
                let diagnosticType = eventCounts[eventType] != nil || eventCounts.count < 16 ? eventType : "other"
                eventCounts[diagnosticType, default: 0] += 1
                switch type {
                case "response.output_text.delta", "response.refusal.delta":
                    guard let delta = value["delta"]?.stringValue else { throw AIProviderError.malformedResponse(.deltaPayload) }
                    textBytes += delta.utf8.count
                    guard textBytes <= 131_072 else { throw AIProviderError.responseLimit }
                    try emit(.textDelta(delta), to: continuation)
                case "response.output_item.added", "response.output_item.done":
                    try streamedOutput.record(value, done: type == "response.output_item.done")
                case "response.completed":
                    guard let completed = value["response"] else { throw AIProviderError.malformedResponse(.terminalEnvelope) }
                    let result = try completion(completed, tools: request.tools, streamedOutput: streamedOutput)
                    guard !result.output.isEmpty else { throw AIProviderError.emptyOutput(eventCounts: eventCounts) }
                    try Task.checkCancellation()
                    try emit(.completed(result), to: continuation)
                    return
                case "response.failed", "error":
                    throw providerFailure(value["response"]?["error"] ?? value["error"] ?? value)
                case "response.incomplete": throw AIProviderError.incomplete
                default: break // Lifecycle/tool argument deltas are committed only by response.completed.
                }
            }
        }
        try decoder.finish()
        throw AIProviderError.streamInterrupted
    }

    private func requestBody(_ request: AIRequest) throws -> Data {
        guard identifier(request.model), !request.input.isEmpty, request.input.count <= 512,
              request.instructions.utf8.count <= 32_768, request.tools.count <= 16,
              Set(request.tools.map(\.name)).count == request.tools.count else { throw AIProviderError.invalidRequest }
        var body: [String: AIJSON] = [
            "model": .string(request.model), "input": .array(request.input),
            "instructions": .string(request.instructions), "store": .bool(false), "stream": .bool(true),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if let schema = request.responseSchema {
            guard schema.objectValue != nil else { throw AIProviderError.invalidRequest }
            body["text"] = .object(["format": .object([
                "type": .string("json_schema"), "name": .string("tern_result"), "strict": .bool(true), "schema": schema
            ])])
        }
        if !request.tools.isEmpty {
            let functions = try request.tools.map { tool -> AIJSON in
                guard tool.name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
                      tool.description.utf8.count <= 4096, tool.parameters.objectValue != nil else { throw AIProviderError.invalidRequest }
                return .object(["type": .string("function"), "name": .string(tool.name),
                                "description": .string(tool.description), "parameters": tool.parameters, "strict": .bool(true)])
            }
            body["tools"] = .array([.object([
                "type": .string("namespace"), "name": .string("tern"),
                "description": .string("Search and read authorized mail, inspect attachments, and prepare editable drafts."),
                "tools": .array(functions)
            ])])
        }
        let data = try AIJSON.object(body).encoded()
        guard data.count <= 524_288 else { throw AIProviderError.invalidRequest }
        return data
    }

    private func completion(_ value: AIJSON, tools: [AIToolDefinition], streamedOutput: StreamedOutput) throws -> AIResponse {
        guard value["status"]?.stringValue == "completed", let terminalOutput = value["output"]?.arrayValue,
              terminalOutput.count <= 128 else { throw AIProviderError.malformedResponse(.terminalOutput) }
        let output = terminalOutput.isEmpty ? try streamedOutput.completedItems() : terminalOutput
        var texts: [String] = []
        var calls: [AIToolCall] = []
        var callIDs: Set<String> = []
        let allowed = Set(tools.map(\.name))
        for item in output {
            switch item["type"]?.stringValue {
            case "reasoning": break // Preserve opaque encrypted content for the next stateless request.
            case "message":
                guard item["role"]?.stringValue == "assistant", item["status"]?.stringValue == "completed",
                      let content = item["content"]?.arrayValue, content.count <= 32 else { throw AIProviderError.malformedResponse(.assistantMessage) }
                for part in content {
                    switch part["type"]?.stringValue {
                    case "output_text":
                        guard let text = part["text"]?.stringValue else { throw AIProviderError.malformedResponse(.outputContent) }
                        texts.append(text)
                    case "refusal":
                        guard let text = part["refusal"]?.stringValue else { throw AIProviderError.malformedResponse(.outputContent) }
                        texts.append(text)
                    default: throw AIProviderError.malformedResponse(.outputContent)
                    }
                }
            case "function_call":
                guard item["namespace"]?.stringValue == "tern", let name = item["name"]?.stringValue, allowed.contains(name),
                      let id = item["call_id"]?.stringValue, identifier(id), callIDs.insert(id).inserted,
                      let arguments = item["arguments"]?.stringValue, arguments.utf8.count <= 65_536,
                      (try? AIJSON.decode(Data(arguments.utf8)).objectValue) != nil,
                      item["status"] == nil || item["status"]?.stringValue == "completed" else { throw AIProviderError.malformedResponse(.functionCall) }
                calls.append(AIToolCall(id: id, namespace: "tern", name: name, arguments: arguments))
            default: throw AIProviderError.malformedResponse(.terminalOutput)
            }
        }
        let text = texts.joined(separator: "\n")
        guard text.utf8.count <= 131_072, calls.count <= 32 else { throw AIProviderError.responseLimit }
        return AIResponse(output: output, text: text, toolCalls: calls, usage: try usage(value["usage"]))
    }

    private func usage(_ value: AIJSON?) throws -> AIUsage? {
        guard let value, value != .null else { return nil }
        func tokenCount(_ name: String) throws -> Int {
            guard let number = value[name]?.numberValue, number >= 0, number < Double(Int.max),
                  number.rounded() == number else { throw AIProviderError.malformedResponse(.usage) }
            return Int(number)
        }
        let input = try tokenCount("input_tokens"), output = try tokenCount("output_tokens"), total = try tokenCount("total_tokens")
        guard input <= Int.max - output, input + output == total else { throw AIProviderError.malformedResponse(.usage) }
        return AIUsage(inputTokens: input, outputTokens: output, totalTokens: total)
    }

    private func authorizedRequest(path: String, method: String) async throws -> URLRequest {
        let token = try await accessToken()
        try Task.checkCancellation()
        guard !token.isEmpty, token.utf8.count <= 16_384, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let url = URL(string: "https://api.openai.com/v1/\(path)") else { throw AIProviderError.signInRequired }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func checkStatus(_ response: AIHTTPResponse) async throws {
        guard (200..<300).contains(response.status) else {
            let body = try? await collect(response.body, limit: 8192)
            let error = body.flatMap { try? AIJSON.decode($0) }?["error"]
            let code = diagnosticIdentifier(error?["code"]?.stringValue)
            let parameter = diagnosticIdentifier(error?["param"]?.stringValue)
            if let code, code.hasPrefix("subscription_sharing_"), response.status != 400 {
                throw providerFailure(error ?? .null)
            }
            switch response.status {
            case 401: throw AIProviderError.signInRequired
            case 403: throw AIProviderError.planUnavailable
            case 429: throw AIProviderError.rateLimited
            case 500...599: throw AIProviderError.unavailable
            default: throw AIProviderError.httpRejected(status: response.status, code: code, parameter: parameter)
            }
        }
    }

    private func diagnosticIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 96,
              value.range(of: #"\A[A-Za-z_][A-Za-z0-9_.\[\]-]*\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private func providerFailure(_ value: AIJSON) -> AIProviderError {
        switch value["code"]?.stringValue {
        case "subscription_sharing_usage_limit_exceeded": .usageLimit
        case "subscription_sharing_user_not_eligible", "subscription_sharing_not_enabled": .planUnavailable
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": .unavailable
        case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported": .invalidRequest
        case "invalid_api_key", "invalid_token", "token_expired": .signInRequired
        case "rate_limit_exceeded": .rateLimited
        default: .unavailable
        }
    }

    private func collect(_ body: AsyncThrowingStream<Data, any Error>, limit: Int) async throws -> Data {
        var result = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            guard chunk.count <= limit - result.count else { throw AIProviderError.responseLimit }
            result.append(chunk)
        }
        return result
    }

    private func emit(_ event: AIEvent, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) throws {
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped: throw AIProviderError.responseLimit
        case .terminated: throw CancellationError()
        @unknown default: throw AIProviderError.streamInterrupted
        }
    }

    private func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }
    }

    private func sanitized(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? AIProviderError { return error }
        if let error = error as? ChatGPTAuthError { return error }
        if let error = error as? URLError, error.code == .timedOut { return AIProviderError.timedOut }
        if error is DecodingError { return AIProviderError.malformedResponse(.jsonDecoding) }
        return AIProviderError.network
    }

    private func deadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: requestTimeout); throw AIProviderError.timedOut }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}

/// Item completion is provisional until the response itself completes. Retain
/// only identities for added items and bounded, final item bodies for done items.
private struct StreamedOutput {
    private struct Entry {
        let identity: [String: AIJSON]
        var completed: AIJSON?
    }
    private var entries: [Int: Entry] = [:]
    private var positions: [String: Int] = [:]
    private var completedBytes = 0

    mutating func record(_ event: AIJSON, done: Bool) throws {
        guard let number = event["output_index"]?.numberValue,
              number >= 0, number < Double(Int.max), number.rounded() == number,
              let item = event["item"], item.objectValue != nil,
              let type = item["type"]?.stringValue, ["message", "reasoning", "function_call"].contains(type)
        else { throw AIProviderError.malformedResponse(.outputItem) }
        let index = Int(number)
        var identities: [String] = []
        if let value = item["id"] {
            guard let id = value.stringValue, validIdentifier(id) else { throw AIProviderError.malformedResponse(.outputItem) }
            identities.append("item:" + id)
        } else if type != "function_call" { throw AIProviderError.malformedResponse(.outputItem) }
        if type == "function_call" {
            guard let callID = item["call_id"]?.stringValue, validIdentifier(callID) else { throw AIProviderError.malformedResponse(.outputItem) }
            identities.append("call:" + callID)
        }
        guard identities.allSatisfy({ positions[$0] == nil || positions[$0] == index }) else { throw AIProviderError.malformedResponse(.outputItem) }
        if let previous = entries[index] {
            guard done, previous.completed == nil,
                  previous.identity.allSatisfy({ item[$0.key] == $0.value }) else { throw AIProviderError.malformedResponse(.outputItem) }
        } else {
            guard entries.count < 128 else { throw AIProviderError.responseLimit }
        }
        var identity: [String: AIJSON] = [:]
        for key in ["id", "type", "call_id", "namespace", "name"] {
            if let value = item[key] { identity[key] = value }
        }
        if done {
            let bytes = try item.encoded().count
            guard bytes <= 2_097_152 - completedBytes else { throw AIProviderError.responseLimit }
            completedBytes += bytes
        }
        entries[index] = Entry(identity: identity, completed: done ? item : nil)
        for identity in identities { positions[identity] = index }
    }

    func completedItems() throws -> [AIJSON] {
        try entries.keys.sorted().map { index in
            guard let item = entries[index]?.completed else { throw AIProviderError.malformedResponse(.outputItem) }
            return item
        }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200
            && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }
    }
}
