import Foundation

/// Names derived from the running app's bundle ID. A build with another ID,
/// such as the benchmark build, gets its own Keychain items and never reads
/// the user's.
enum AppIdentity {
    /// The generic-password items Tern keeps in the login keychain.
    enum KeychainItem: String, Sendable {
        /// Google tokens, one item per account.
        case oauth
        /// The ChatGPT connection.
        case chatGPT = "chatgpt"
        /// API keys, one item per provider.
        case apiKey = "ai-api-key"
    }

    /// The running app's bundle ID.
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.tern.mail"

    /// The Keychain service name for `item` in the app with `bundleIdentifier`.
    /// Saved items are looked up by these names, so the names for
    /// `dev.tern.mail` must never change.
    static func keychainService(_ item: KeychainItem,
                                bundleIdentifier: String = AppIdentity.bundleIdentifier) -> String {
        bundleIdentifier + "." + item.rawValue
    }
}
