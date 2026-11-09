import Foundation

/// Tool calls remain provisional until every block and the message have finished.
struct AnthropicStream {
    private struct Block {
        var value: [String: AIJSON]
        var arguments = ""
        var receivedArguments = false
        var stopped = false
    }

    private let allowedTools: Set<String>
    private var blocks: [Block] = []
    private var messageID: String?
    private var stopReason: String?
    private var ended = false
    private var textBytes = 0
    private var contentBytes = 0
    private var callIDs: Set<String> = []
    private var inputTokens = 0
    private var cacheCreationTokens = 0
    private var cacheReadTokens = 0
    private var outputTokens = 0

    init(tools: [AIToolDefinition]) { allowedTools = Set(tools.map(\.name)) }

    mutating func accept(_ event: SSEEvent) throws -> [AIEvent] {
        guard !ended else { throw AIProviderError.malformedResponse(.eventEnvelope) }
        let value: AIJSON
        do { value = try AIJSON.decode(Data(event.data.utf8)) }
        catch { throw AIProviderError.malformedResponse(.eventJSON) }
        guard let type = value["type"]?.stringValue, event.name == "message" || event.name == type else {
            throw AIProviderError.malformedResponse(.eventEnvelope)
        }
        switch type {
        case "error": throw AnthropicProvider.streamError(value["error"])
        case "message_start":
            guard messageID == nil, let message = value["message"],
                  message["type"]?.stringValue == "message", message["role"]?.stringValue == "assistant",
                  let id = message["id"]?.stringValue, AnthropicRequest.identifier(id),
                  message["content"]?.arrayValue == [] else { throw AIProviderError.malformedResponse(.assistantMessage) }
            messageID = id
            if let usage = message["usage"] { try updateUsage(usage) }
            return []
        case "content_block_start": return try start(value)
        case "content_block_delta": return try delta(value)
        case "content_block_stop":
            let index = try blockIndex(value)
            guard messageID != nil, stopReason == nil, !blocks[index].stopped else {
                throw AIProviderError.malformedResponse(.outputItem)
            }
            try finishBlock(at: index)
            blocks[index].stopped = true
            return []
        case "message_delta":
            guard messageID != nil, blocks.allSatisfy(\.stopped), let delta = value["delta"]?.objectValue else {
                throw AIProviderError.malformedResponse(.terminalEnvelope)
            }
            if let reason = delta["stop_reason"], reason != .null {
                guard let text = reason.stringValue, stopReason == nil || stopReason == text else {
                    throw AIProviderError.malformedResponse(.terminalEnvelope)
                }
                stopReason = text
            }
            if let usage = value["usage"] { try updateUsage(usage) }
            return []
        case "message_stop":
            let result = try completion()
            ended = true
            return [.completed(result)]
        default: return [] // Pings and future lifecycle events do not commit content.
        }
    }

    private mutating func start(_ value: AIJSON) throws -> [AIEvent] {
        guard messageID != nil, stopReason == nil,
              value["index"]?.numberValue == Double(blocks.count), blocks.count < 128,
              let content = value["content_block"]?.objectValue, let type = content["type"]?.stringValue else {
            throw AIProviderError.malformedResponse(.outputItem)
        }
        switch type {
        case "text":
            guard let text = content["text"]?.stringValue else { throw AIProviderError.malformedResponse(.outputContent) }
            try count(text, text: true)
            blocks.append(Block(value: ["type": .string(type), "text": .string(text)]))
            return text.isEmpty ? [] : [.textDelta(text)]
        case "tool_use":
            guard let id = content["id"]?.stringValue, AnthropicRequest.identifier(id), callIDs.insert(id).inserted,
                  callIDs.count <= 32, let name = content["name"]?.stringValue, allowedTools.contains(name),
                  let input = content["input"], input.objectValue != nil else {
                throw AIProviderError.malformedResponse(.functionCall)
            }
            guard try input.encoded().count <= 65_536 else { throw AIProviderError.responseLimit }
            blocks.append(Block(value: ["type": .string(type), "id": .string(id), "name": .string(name), "input": input]))
        case "thinking":
            guard let thinking = content["thinking"]?.stringValue, let signature = content["signature"]?.stringValue else {
                throw AIProviderError.malformedResponse(.outputContent)
            }
            try count(thinking); try count(signature)
            blocks.append(Block(value: ["type": .string(type), "thinking": .string(thinking), "signature": .string(signature)]))
        case "redacted_thinking":
            guard let data = content["data"]?.stringValue, !data.isEmpty else {
                throw AIProviderError.malformedResponse(.outputContent)
            }
            try count(data)
            blocks.append(Block(value: ["type": .string(type), "data": .string(data)]))
        default: throw AIProviderError.malformedResponse(.outputContent)
        }
        return []
    }

    private mutating func delta(_ value: AIJSON) throws -> [AIEvent] {
        let index = try blockIndex(value)
        guard messageID != nil, stopReason == nil, !blocks[index].stopped,
              let delta = value["delta"], let type = delta["type"]?.stringValue else {
            throw AIProviderError.malformedResponse(.deltaPayload)
        }
        let blockType = blocks[index].value["type"]?.stringValue
        switch (blockType, type) {
        case ("text", "text_delta"):
            guard let text = delta["text"]?.stringValue else { throw AIProviderError.malformedResponse(.deltaPayload) }
            try count(text, text: true)
            blocks[index].value["text"] = .string((blocks[index].value["text"]?.stringValue ?? "") + text)
            return text.isEmpty ? [] : [.textDelta(text)]
        case ("tool_use", "input_json_delta"):
            guard let fragment = delta["partial_json"]?.stringValue,
                  blocks[index].value["input"] == .object([:]),
                  fragment.utf8.count <= 65_536 - blocks[index].arguments.utf8.count else {
                throw AIProviderError.malformedResponse(.functionCall)
            }
            try count(fragment)
            blocks[index].receivedArguments = true
            blocks[index].arguments += fragment
        case ("thinking", "thinking_delta"), ("thinking", "signature_delta"):
            let key = type == "thinking_delta" ? "thinking" : "signature"
            guard let text = delta[key]?.stringValue else { throw AIProviderError.malformedResponse(.deltaPayload) }
            try count(text)
            blocks[index].value[key] = .string((blocks[index].value[key]?.stringValue ?? "") + text)
        default: throw AIProviderError.malformedResponse(.deltaPayload)
        }
        return []
    }

    private mutating func finishBlock(at index: Int) throws {
        switch blocks[index].value["type"]?.stringValue {
        case "tool_use":
            if blocks[index].receivedArguments {
                guard let parsed = try? AIJSON.decode(Data(blocks[index].arguments.utf8)), parsed.objectValue != nil else {
                    throw AIProviderError.malformedResponse(.functionCall)
                }
                blocks[index].value["input"] = parsed
            }
        case "thinking", "redacted_thinking":
            guard AnthropicRequest.validThinking(.object(blocks[index].value)) else {
                throw AIProviderError.malformedResponse(.outputContent)
            }
        default: break
        }
    }

    private func completion() throws -> AIResponse {
        guard let messageID, let stopReason, blocks.allSatisfy(\.stopped) else {
            throw AIProviderError.malformedResponse(.terminalEnvelope)
        }
        guard ["end_turn", "stop_sequence", "tool_use", "refusal"].contains(stopReason) else {
            throw AIProviderError.incomplete
        }
        guard (stopReason == "tool_use") == !callIDs.isEmpty else { throw AIProviderError.incomplete }
        var output: [AIJSON] = []
        var texts: [String] = []
        var calls: [AIToolCall] = []
        for (index, block) in blocks.enumerated() {
            let value = AIJSON.object(block.value)
            switch value["type"]?.stringValue {
            case "text":
                guard let text = value["text"]?.stringValue else { throw AIProviderError.malformedResponse(.outputContent) }
                guard !text.isEmpty else { continue }
                texts.append(text)
                output.append(.object(["type": .string("message"), "id": .string("\(messageID)_\(index)"),
                    "role": .string("assistant"), "status": .string("completed"),
                    "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])]))
            case "tool_use":
                guard let id = value["id"]?.stringValue, let name = value["name"]?.stringValue,
                      let arguments = value["input"] else { throw AIProviderError.malformedResponse(.functionCall) }
                let encoded = try arguments.jsonString()
                calls.append(AIToolCall(id: id, namespace: "tern", name: name, arguments: encoded))
                output.append(.object(["type": .string("function_call"), "namespace": .string("tern"),
                    "call_id": .string(id), "name": .string(name), "arguments": .string(encoded), "status": .string("completed")]))
            case "thinking", "redacted_thinking":
                output.append(.object(["type": .string("reasoning"), "anthropic_content": value]))
            default: throw AIProviderError.malformedResponse(.terminalOutput)
            }
        }
        guard !texts.isEmpty || !calls.isEmpty else { throw AIProviderError.emptyOutput(eventCounts: [:]) }
        let input = try sum([inputTokens, cacheCreationTokens, cacheReadTokens])
        let total = try sum([input, outputTokens])
        return AIResponse(output: output, text: texts.joined(separator: "\n"), toolCalls: calls,
            usage: AIUsage(inputTokens: input, outputTokens: outputTokens, totalTokens: total))
    }

    private func blockIndex(_ value: AIJSON) throws -> Int {
        guard let number = value["index"]?.numberValue, number >= 0,
              number < Double(blocks.count), number.rounded() == number else {
            throw AIProviderError.malformedResponse(.outputItem)
        }
        return Int(number)
    }

    private mutating func count(_ string: String, text: Bool = false) throws {
        let size = string.utf8.count
        guard size <= 1_048_576 - contentBytes, !text || size <= 131_072 - textBytes else {
            throw AIProviderError.responseLimit
        }
        contentBytes += size
        if text { textBytes += size }
    }

    private mutating func updateUsage(_ value: AIJSON) throws {
        guard value.objectValue != nil else { throw AIProviderError.malformedResponse(.usage) }
        func count(_ name: String, previous: Int) throws -> Int {
            guard let entry = value[name] else { return previous }
            guard let number = entry.numberValue, number >= Double(previous), number < Double(Int.max),
                  number.rounded() == number else { throw AIProviderError.malformedResponse(.usage) }
            return Int(number)
        }
        inputTokens = try count("input_tokens", previous: inputTokens)
        outputTokens = try count("output_tokens", previous: outputTokens)
        cacheCreationTokens = try count("cache_creation_input_tokens", previous: cacheCreationTokens)
        cacheReadTokens = try count("cache_read_input_tokens", previous: cacheReadTokens)
    }

    private func sum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { total, next in
            guard next <= Int.max - total else { throw AIProviderError.malformedResponse(.usage) }
            return total + next
        }
    }
}
