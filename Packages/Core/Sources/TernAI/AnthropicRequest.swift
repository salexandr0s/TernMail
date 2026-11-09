import Foundation

/// Converts the assistant's stateless history without changing message roles.
enum AnthropicRequest {
    static let maximumBytes = 524_288

    static func encode(_ request: AIRequest) throws -> Data {
        guard identifier(request.model), !request.input.isEmpty, request.input.count <= 512,
              request.instructions.utf8.count <= 32_768, request.tools.count <= 16,
              Set(request.tools.map(\.name)).count == request.tools.count,
              try AIJSON.array(request.input).encoded().count <= maximumBytes else { throw AIProviderError.invalidRequest }
        var body: [String: AIJSON] = [
            "model": .string(request.model), "messages": .array(try messages(request.input)),
            "system": .string(request.instructions), "max_tokens": .number(16_384), "stream": .bool(true),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(try request.tools.map { tool in
                guard toolName(tool.name), tool.description.utf8.count <= 4096,
                      tool.parameters.objectValue != nil else { throw AIProviderError.invalidRequest }
                // Ordinary tools avoid Claude's shared strict-schema grammar limit.
                // The app validates every tool argument before performing an action.
                return .object(["name": .string(tool.name), "description": .string(tool.description),
                    "input_schema": tool.parameters])
            })
        }
        if let schema = request.responseSchema {
            guard schema.objectValue != nil else { throw AIProviderError.invalidRequest }
            body["output_config"] = .object(["format": .object([
                "type": .string("json_schema"), "schema": try structuredSchema(schema)
            ])])
        }
        let data = try AIJSON.object(body).encoded()
        guard data.count <= maximumBytes else { throw AIProviderError.invalidRequest }
        return data
    }

    private struct Message {
        let role: String
        var content: [AIJSON]
        var json: AIJSON { .object(["role": .string(role), "content": .array(content)]) }
    }

    private static func messages(_ input: [AIJSON]) throws -> [AIJSON] {
        var result: [Message] = []
        var calls: Set<String> = []
        var pending: Set<String> = []
        func append(role: String, parts: [AIJSON]) {
            if result.last?.role == role { result[result.count - 1].content += parts }
            else { result.append(Message(role: role, content: parts)) }
        }
        for item in input {
            switch item["type"]?.stringValue {
            case "function_call":
                guard item["namespace"]?.stringValue == "tern",
                      let id = item["call_id"]?.stringValue, identifier(id), calls.insert(id).inserted,
                      let name = item["name"]?.stringValue, toolName(name),
                      let text = item["arguments"]?.stringValue, text.utf8.count <= 65_536,
                      let arguments = try? AIJSON.decode(Data(text.utf8)), arguments.objectValue != nil,
                      result.last?.role == "assistant" || pending.isEmpty else { throw AIProviderError.invalidRequest }
                pending.insert(id)
                append(role: "assistant", parts: [.object(["type": .string("tool_use"),
                    "id": .string(id), "name": .string(name), "input": arguments])])
            case "function_call_output":
                guard let id = item["call_id"]?.stringValue, pending.remove(id) != nil,
                      let output = item["output"]?.stringValue else { throw AIProviderError.invalidRequest }
                append(role: "user", parts: [.object(["type": .string("tool_result"),
                    "tool_use_id": .string(id), "content": .string(output)])])
            case "reasoning":
                guard let block = item["anthropic_content"], validThinking(block),
                      result.last?.role == "assistant" || pending.isEmpty else { throw AIProviderError.invalidRequest }
                append(role: "assistant", parts: [block])
            case nil, "message":
                guard let role = item["role"]?.stringValue, ["user", "assistant"].contains(role),
                      role == "assistant" ? (result.last?.role == "assistant" || pending.isEmpty) : pending.isEmpty,
                      let content = item["content"] else { throw AIProviderError.invalidRequest }
                append(role: role, parts: try contentParts(content, role: role))
            default: throw AIProviderError.invalidRequest
            }
        }
        guard pending.isEmpty, result.first?.role == "user", result.last?.role == "user" else {
            throw AIProviderError.invalidRequest
        }
        return result.map(\.json)
    }

    private static func contentParts(_ value: AIJSON, role: String) throws -> [AIJSON] {
        if let text = value.stringValue {
            guard !text.isEmpty else { throw AIProviderError.invalidRequest }
            return [.object(["type": .string("text"), "text": .string(text)])]
        }
        guard let parts = value.arrayValue, !parts.isEmpty, parts.count <= 128 else { throw AIProviderError.invalidRequest }
        return try parts.map { part in
            switch part["type"]?.stringValue {
            case "input_text", "output_text":
                guard let text = part["text"]?.stringValue else { throw AIProviderError.invalidRequest }
                return .object(["type": .string("text"), "text": .string(text)])
            case "refusal":
                guard role == "assistant", let text = part["refusal"]?.stringValue else { throw AIProviderError.invalidRequest }
                return .object(["type": .string("text"), "text": .string(text)])
            case "input_image":
                guard role == "user", let url = part["image_url"]?.stringValue else { throw AIProviderError.invalidRequest }
                return try image(url)
            default: throw AIProviderError.invalidRequest
            }
        }
    }

    private static func image(_ url: String) throws -> AIJSON {
        guard let separator = url.range(of: ";base64,"), url.hasPrefix("data:"),
              url.utf8.count <= maximumBytes else { throw AIProviderError.invalidRequest }
        let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<separator.lowerBound])
        let encoded = String(url[separator.upperBound...])
        guard ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime),
              !encoded.isEmpty, Data(base64Encoded: encoded) != nil else { throw AIProviderError.invalidRequest }
        return .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string(mime), "data": .string(encoded)
        ])])
    }

    /// Claude requires signed thinking blocks unchanged when returning tool results.
    static func validThinking(_ value: AIJSON) -> Bool {
        guard let object = value.objectValue else { return false }
        switch value["type"]?.stringValue {
        case "thinking":
            return Set(object.keys) == ["type", "thinking", "signature"]
                && value["thinking"]?.stringValue != nil && value["signature"]?.stringValue?.isEmpty == false
        case "redacted_thinking":
            return Set(object.keys) == ["type", "data"] && value["data"]?.stringValue?.isEmpty == false
        default: return false
        }
    }

    /// Match Claude's documented schema adaptation; domain decoders retain the original constraints.
    private static func structuredSchema(_ schema: AIJSON, depth: Int = 0) throws -> AIJSON {
        guard depth <= 32, var object = schema.objectValue else { throw AIProviderError.invalidRequest }
        var constraints: [String] = []
        let unsupported = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
                           "minLength", "maxLength", "maxItems", "uniqueItems", "minContains", "maxContains"]
        for key in unsupported {
            if let value = object.removeValue(forKey: key) { constraints.append("\(key): \(try value.jsonString())") }
        }
        if let minimum = object["minItems"], minimum != .number(0), minimum != .number(1) {
            object.removeValue(forKey: "minItems")
            constraints.append("minItems: \(try minimum.jsonString())")
        }
        if !constraints.isEmpty {
            let previous = object["description"]?.stringValue ?? ""
            object["description"] = .string(([previous] + constraints).filter { !$0.isEmpty }.joined(separator: "; "))
        }
        for key in ["properties", "$defs", "definitions"] {
            if let entries = object[key]?.objectValue {
                object[key] = .object(try entries.mapValues { try structuredSchema($0, depth: depth + 1) })
            }
        }
        if let items = object["items"] { object["items"] = try structuredSchema(items, depth: depth + 1) }
        for key in ["anyOf", "allOf", "oneOf"] {
            if let alternatives = object[key]?.arrayValue {
                object[key] = .array(try alternatives.map { try structuredSchema($0, depth: depth + 1) })
            }
        }
        if object["type"] == .string("object") || object["properties"] != nil {
            guard object["additionalProperties"] == nil || object["additionalProperties"] == .bool(false) else {
                throw AIProviderError.invalidRequest
            }
            object["additionalProperties"] = .bool(false)
        }
        return .object(object)
    }

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200
            && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }
    }

    static func toolName(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z_][A-Za-z0-9_]{0,63}\z"#, options: .regularExpression) != nil
    }
}
