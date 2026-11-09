import Foundation

/// The authentication route is part of the service identity, so API keys and
/// ChatGPT subscription credentials cannot be substituted for each other.
public enum AIService: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPT
    case claudeCode
    case openAI
    case anthropic
    case deepSeek

    public var id: String { rawValue }
    public var usesAPIKey: Bool { self != .chatGPT && self != .claudeCode }
    public var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claudeCode: "Claude (CLI)"
        case .openAI: "OpenAI API"
        case .anthropic: "Claude API"
        case .deepSeek: "DeepSeek API"
        }
    }
}
