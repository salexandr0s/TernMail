import Foundation

/// The authentication route is part of the service identity, so API keys and
/// ChatGPT subscription credentials cannot be substituted for each other.
public enum AIService: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPT
    case openAI
    case anthropic
    case deepSeek

    public var id: String { rawValue }
    public var usesAPIKey: Bool { self != .chatGPT }
    public var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .openAI: "OpenAI API"
        case .anthropic: "Claude API"
        case .deepSeek: "DeepSeek API"
        }
    }
}
