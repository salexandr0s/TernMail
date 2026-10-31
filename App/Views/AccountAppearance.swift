import Foundation
import MailStore
import SwiftUI

/// How the sidebar tells accounts apart: a color from a small palette and a
/// short name. Colors are stored by account ID, so an account keeps its color
/// when others are added or removed.
enum AccountAppearance {
    /// The `UserDefaults` key holding the stored palette indexes.
    static let storageKey = "accountColors"

    struct Swatch: Sendable {
        let name: String
        let color: Color
    }

    static let palette: [Swatch] = [
        Swatch(name: "Blue", color: .blue), Swatch(name: "Pink", color: .pink),
        Swatch(name: "Orange", color: .orange), Swatch(name: "Green", color: .green),
        Swatch(name: "Purple", color: .purple), Swatch(name: "Teal", color: .teal),
        Swatch(name: "Indigo", color: .indigo), Swatch(name: "Brown", color: .brown)
    ]

    /// Palette indexes for `accountIDs`. An account in `stored` keeps its
    /// index. Each new account takes the index the fewest listed accounts
    /// use, the lowest first, so no two share a color while the palette has
    /// a free one. Accounts that aren't listed are dropped.
    static func colorIndexes(for accountIDs: [String], stored: [String: Int]) -> [String: Int] {
        var indexes = stored.filter { accountIDs.contains($0.key) && palette.indices.contains($0.value) }
        for id in accountIDs where indexes[id] == nil {
            var uses = Array(repeating: 0, count: palette.count)
            for index in indexes.values { uses[index] += 1 }
            indexes[id] = uses.indices.min { uses[$0] < uses[$1] } ?? 0
        }
        return indexes
    }

    static func color(at index: Int?) -> Color {
        index.flatMap { palette.indices.contains($0) ? palette[$0].color : nil } ?? .secondary
    }

    /// Each account's address up to the @, or the whole address when another
    /// account's address starts with the same name.
    static func shortNames(_ accounts: [AccountRecord]) -> [String: String] {
        func name(_ email: String) -> String { String(email.prefix { $0 != "@" }) }
        let uses = Dictionary(accounts.map { (name($0.email).lowercased(), 1) }, uniquingKeysWith: +)
        return Dictionary(accounts.map { account in
            let short = name(account.email)
            return (account.id, uses[short.lowercased(), default: 0] > 1 ? account.email : short)
        }, uniquingKeysWith: { first, _ in first })
    }

    static func decode(_ data: Data) -> [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    static func encode(_ indexes: [String: Int]) -> Data {
        (try? JSONEncoder().encode(indexes)) ?? Data()
    }
}
