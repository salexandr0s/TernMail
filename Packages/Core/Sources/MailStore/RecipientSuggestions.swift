import Foundation
import GRDB
import MessageContent

extension MailCache {
    /// Frequent correspondents retain their ranking. Saved contacts supply names
    /// and follow them, then other contacts; prefix matches lead each group.
    /// Case and accents don't matter.
    public func recipientSuggestions(
        accountID: String, matching text: String, excluding excluded: Set<String> = [],
        includeContacts: Bool = true, limit: Int = 8
    ) async throws -> [EmailAddress] {
        let query = SearchFolding.folded(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty, limit > 0 else { return [] }
        let mail = try await addressSuggestions(accountID: accountID, matching: text, excluding: excluded, limit: max(limit, 50))
        guard includeContacts else { return Array(mail.prefix(limit)) }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let placeholders = Array(repeating: "?", count: mail.count).joined(separator: ",")
        let arguments = StatementArguments([accountID, "%\(escaped)%", "%\(escaped)%"] + mail.map(\.normalized))
        let contacts = try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.address, e.lowercasedAddress, c.displayName, c.source
                FROM contactEmail e JOIN contact c
                  ON c.accountID = e.accountID AND c.source = e.source AND c.resourceName = e.resourceName
                WHERE e.accountID = ? AND (e.addressSearch LIKE ? ESCAPE '\\'
                  OR c.nameSearch LIKE ? ESCAPE '\\'
                  OR e.lowercasedAddress IN (\(placeholders.isEmpty ? "NULL" : placeholders)))
                ORDER BY CASE c.source WHEN 'connection' THEN 0 ELSE 1 END,
                  c.displayName COLLATE NOCASE, e.lowercasedAddress
                LIMIT 500
                """, arguments: arguments)
                .map { row in
                    ContactSuggestion(address: row["address"], name: row["displayName"], saved: row["source"] == "connection")
                }
        }
        var entries: [String: RankedRecipient] = [:]
        for (index, address) in mail.enumerated() {
            entries[address.normalized] = RankedRecipient(address: address, source: 0, mailOrder: index)
        }
        for contact in contacts {
            let address = EmailAddress(name: contact.name, address: contact.address)
            guard address.isValid, !excluded.contains(address.normalized) else { continue }
            if var existing = entries[address.normalized] {
                if let name = contact.name, (contact.saved && !existing.hasSavedName) || existing.address.name == nil {
                    existing.address.name = name
                    existing.hasSavedName = contact.saved
                    entries[address.normalized] = existing
                }
            } else {
                entries[address.normalized] = RankedRecipient(
                    address: address, source: contact.saved ? 1 : 2, mailOrder: 0, hasSavedName: contact.saved && contact.name != nil
                )
            }
        }
        // Folding costs more than a comparison, so each entry is checked once.
        let prefixes = Set(entries.filter { $0.value.address.isSuggestionPrefix(query) }.keys)
        return entries.sorted { left, right in
            let leftPrefix = prefixes.contains(left.key)
            let rightPrefix = prefixes.contains(right.key)
            if leftPrefix != rightPrefix { return leftPrefix }
            let (lhs, rhs) = (left.value, right.value)
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            if lhs.source == 0, lhs.mailOrder != rhs.mailOrder { return lhs.mailOrder < rhs.mailOrder }
            let leftName = (lhs.address.name ?? lhs.address.address).lowercased()
            let rightName = (rhs.address.name ?? rhs.address.address).lowercased()
            if leftName != rightName { return leftName < rightName }
            return left.key < right.key
        }.prefix(limit).map(\.value.address)
    }
}

private struct ContactSuggestion: Sendable {
    let address: String
    let name: String?
    let saved: Bool
}

private struct RankedRecipient {
    var address: EmailAddress
    let source: Int
    let mailOrder: Int
    var hasSavedName = false
}

private extension EmailAddress {
    /// `query` is folded with `SearchFolding`.
    func isSuggestionPrefix(_ query: String) -> Bool {
        SearchFolding.folded(normalized).hasPrefix(query) || SearchFolding.folded(name ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." }).contains { $0.hasPrefix(query) }
    }
}
