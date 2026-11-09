import Foundation

/// Text with case and accents folded away, so "γιώ" matches "Γιώργος" and
/// "elo" matches "Élodie". SQLite's `LIKE` and `lower` fold ASCII only, so
/// columns searched with `LIKE` store text folded here, and each query is
/// folded the same way.
enum SearchFolding {
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// The headers address completion looks through in a message.
    static func addresses(sender: String, recipients: String, cc: String?) -> String {
        folded([sender, recipients, cc ?? ""].joined(separator: "\n"))
    }
}
