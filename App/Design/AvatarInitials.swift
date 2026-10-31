import Foundation

/// Letters for an avatar that has no photo or logo.
enum AvatarInitials {
    /// The first letters of the first and last words, or the first two letters of a single word, in capitals.
    /// Uses `name`, or `address` when the name is blank. Quotes and everything from "<" or "@" on are ignored,
    /// so a "Name <address>" string or a bare address also works. Empty when no word remains.
    static func from(name: String, address: String = "") -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? address : trimmed
        let words = value.prefix { $0 != "<" && $0 != "@" }
            .split { $0.isWhitespace || $0 == "\"" || $0 == "." || $0 == "_" || $0 == "-" }
        guard let first = words.first else { return "" }
        if words.count > 1, let last = words.last {
            return (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }
}
