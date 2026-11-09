import Foundation

/// Differences between subscription inference and the public Responses APIs.
enum ResponsesAPIContract {
    static func models(_ value: AIJSON, service: AIService) throws -> [AIModel] {
        guard let entries = value["data"]?.arrayValue else { throw AIProviderError.invalidResponse }
        guard entries.count <= 1_000 else { throw AIProviderError.catalogueLimit }
        var seen: Set<String> = []
        var models: [AIModel] = []
        for entry in entries {
            guard let id = entry["id"]?.stringValue, validIdentifier(id) else { throw AIProviderError.invalidResponse }
            guard supportedModel(id, service: service) else { continue }
            guard seen.insert(id).inserted else { throw AIProviderError.invalidResponse }
            let name = service == .deepSeek ? entry["name"]?.stringValue ?? id : id
            guard !name.isEmpty, name.utf8.count <= 256,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw AIProviderError.invalidResponse
            }
            var images = supportsImages(id, service: service)
            if service == .deepSeek, let modalities = entry["input_modalities"] {
                guard let values = modalities.arrayValue, values.allSatisfy({ $0.stringValue != nil }),
                      values.contains(.string("text")) else { throw AIProviderError.invalidResponse }
                images = images && values.contains(.string("image"))
            }
            models.append(AIModel(id: id, displayName: name, supportsImages: images))
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func requestBody(_ original: [String: AIJSON], request: AIRequest, service: AIService) throws -> [String: AIJSON] {
        guard supportedModel(request.model, service: service) else { throw AIProviderError.invalidRequest }
        if request.input.contains(where: containsImage), !supportsImages(request.model, service: service) {
            throw AIProviderError.unsupportedImages
        }
        var body = original
        body["input"] = .array(try request.input.map { try wireInput($0, service: service) })
        if let namespace = original["tools"]?.arrayValue?.first,
           let functions = namespace["tools"]?.arrayValue {
            body["tools"] = .array(functions.map { function in
                guard service == .deepSeek, var fields = function.objectValue else { return function }
                fields.removeValue(forKey: "strict")
                return .object(fields)
            })
        }
        if service == .deepSeek {
            body.removeValue(forKey: "store")
            body.removeValue(forKey: "include")
            body["reasoning"] = .object(["effort": .string("none")])
            if var text = body["text"]?.objectValue, var format = text["format"]?.objectValue {
                format.removeValue(forKey: "strict")
                text["format"] = .object(format)
                body["text"] = .object(text)
            }
        }
        return body
    }

    /// App tool dispatch uses the same namespace regardless of the wire format.
    /// Streamed items remain provisional until the response completes.
    static func canonicalOutput(_ item: AIJSON) throws -> AIJSON {
        guard item["type"]?.stringValue == "function_call" else { return item }
        guard var fields = item.objectValue,
              fields["namespace"] == nil || fields["namespace"] == .null || fields["namespace"] == .string("tern") else {
            throw AIProviderError.malformedResponse(.functionCall)
        }
        fields["namespace"] = .string("tern")
        for field in ["id", "status"] where fields[field] == .null { fields.removeValue(forKey: field) }
        return .object(fields)
    }

    private static func wireInput(_ item: AIJSON, service: AIService) throws -> AIJSON {
        guard var fields = item.objectValue else { throw AIProviderError.invalidRequest }
        if fields["type"] == .string("function_call") {
            guard fields["namespace"] == nil || fields["namespace"] == .string("tern") else {
                throw AIProviderError.invalidRequest
            }
            fields.removeValue(forKey: "namespace")
        }
        if service == .deepSeek, fields["type"] == .string("reasoning"), fields["encrypted_content"] != nil {
            // A foreign provider's opaque state must never be treated as reusable history.
            throw AIProviderError.invalidRequest
        }
        return .object(fields)
    }

    static func supportedModel(_ id: String, service: AIService) -> Bool {
        switch service {
        case .deepSeek: return ["deepseek-flash", "deepseek-v4-pro"].contains(id)
        case .openAI:
            // /models also returns image, audio, embedding and legacy chat models.
            // These documented models support tools, images and JSON schema.
            let bases = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano",
                         "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.2", "gpt-5.4",
                         "gpt-5.4-mini", "gpt-5.4-nano", "gpt-6-sol", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]
            if bases.contains(id) { return true }
            guard let suffix = id.range(of: #"-[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) else { return false }
            let base = String(id[..<suffix.lowerBound])
            guard bases.contains(base) else { return false }
            // The original GPT-4o snapshot predates structured output support.
            return base != "gpt-4o" || String(id[suffix]) >= "-2024-08-06"
        default: return false
        }
    }

    private static func supportsImages(_ id: String, service: AIService) -> Bool {
        service == .openAI || (service == .deepSeek && id == "deepseek-flash")
    }

    private static func containsImage(_ value: AIJSON) -> Bool {
        switch value {
        case .object(let fields): fields["type"] == .string("input_image") || fields.values.contains(where: containsImage)
        case .array(let values): values.contains(where: containsImage)
        default: false
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200
            && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }
    }
}
