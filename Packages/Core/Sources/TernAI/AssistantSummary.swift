import Foundation

/// Shared result for chat, the reader summary bubble, and later commitment views.
public struct AssistantSummary: Codable, Equatable, Sendable {
    public struct Decision: Codable, Equatable, Sendable {
        public let text: String
        public let sourceIDs: [String]
        enum CodingKeys: String, CodingKey { case text; case sourceIDs = "source_ids" }
    }

    public struct OpenTask: Codable, Equatable, Sendable {
        public let description: String
        public let owner: String?
        public let dueDate: String?
        public let sourceIDs: [String]
        enum CodingKeys: String, CodingKey {
            case description, owner
            case dueDate = "due_date"
            case sourceIDs = "source_ids"
        }
    }

    public let summary: String
    public let sourceIDs: [String]
    public let decisions: [Decision]
    public let openTasks: [OpenTask]
    enum CodingKeys: String, CodingKey {
        case summary, decisions
        case sourceIDs = "source_ids"
        case openTasks = "open_tasks"
    }

    public static func decode(_ data: Data, allowedSourceIDs: Set<String>) throws -> AssistantSummary {
        guard data.count <= 100_000 else { throw AIProviderError.responseLimit }
        let result = try JSONDecoder().decode(Self.self, from: data)
        func validText(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 20_000
        }
        func validSources(_ values: [String]) -> Bool {
            !values.isEmpty && values.count <= 100 && Set(values).count == values.count
                && values.allSatisfy(allowedSourceIDs.contains)
        }
        guard validText(result.summary), validSources(result.sourceIDs),
              result.decisions.count <= 100, result.openTasks.count <= 100,
              result.decisions.allSatisfy({ validText($0.text) && validSources($0.sourceIDs) }),
              result.openTasks.allSatisfy({
                  validText($0.description) && ($0.owner.map(validText) ?? true)
                      && ($0.dueDate.map(validDate) ?? true) && validSources($0.sourceIDs)
              }) else { throw AIProviderError.invalidResponse }
        return result
    }

    public static var schema: AIJSON {
        let string = AIJSON.object(["type": .string("string")])
        let optionalString = AIJSON.object(["type": .array([.string("string"), .string("null")])])
        let sources = AIJSON.object(["type": .string("array"), "items": string])
        let decision = objectSchema(["text": string, "source_ids": sources])
        let task = objectSchema(["description": string, "owner": optionalString, "due_date": optionalString, "source_ids": sources])
        return objectSchema([
            "summary": string, "source_ids": sources,
            "decisions": .object(["type": .string("array"), "items": decision]),
            "open_tasks": .object(["type": .string("array"), "items": task]),
        ])
    }

    private static func objectSchema(_ properties: [String: AIJSON]) -> AIJSON {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(properties.keys.sorted().map(AIJSON.string)), "additionalProperties": .bool(false)])
    }

    private static func validDate(_ value: String) -> Bool {
        guard value.count == 10, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
