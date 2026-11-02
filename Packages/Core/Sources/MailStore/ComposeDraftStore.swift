import Foundation
import GRDB
import MessageContent

extension CacheTransaction {
    public func setOutgoingContentID(id: Int64, contentID: String, now: Date) throws -> OutgoingAttachment? {
        guard InlineImageReference(contentID: contentID).isValid,
              var attachment = try OutgoingAttachment.fetchOne(db, key: id),
              var draft = try localDraft(id: attachment.localDraftID), draft.state == .editing else { return nil }
        attachment.contentID = contentID
        try attachment.update(db)
        draft.revision += 1; draft.updatedAt = now
        try draft.update(db)
        return attachment
    }

    public func replaceDraftQuote(id: String, text: String, now: Date) throws {
        guard var draft = try localDraft(id: id), draft.state == .editing else { return }
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        draft.quotedPlainText = isEmpty ? nil : text
        draft.quotedHTML = isEmpty ? nil : "<blockquote>" + ComposeDocument(plainText: text).html() + "</blockquote>"
        draft.revision += 1; draft.updatedAt = now
        try draft.update(db)
    }
}

extension MailCache {
    /// Exact parsed addresses decide after a bounded SQL prefilter; substrings never select an account.
    public func lastCorrespondenceAccount(with address: String, accountIDs: [String]) async throws -> String? {
        guard !accountIDs.isEmpty, EmailAddress(address: address).isValid else { return nil }
        let normalized = address.lowercased()
        let escaped = normalized.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let placeholders = Array(repeating: "?", count: accountIDs.count).joined(separator: ",")
        let arguments = StatementArguments(accountIDs + Array(repeating: "%\(escaped)%", count: 3))
        return try await writer.read { db in
            let rows = try MessageRecord.fetchAll(db, sql: """
                SELECT * FROM message WHERE accountID IN (\(placeholders))
                  AND (sender LIKE ? ESCAPE '\\' OR recipients LIKE ? ESCAPE '\\' OR cc LIKE ? ESCAPE '\\')
                ORDER BY date DESC, accountID, id LIMIT 500
                """, arguments: arguments)
            return rows.first { row in
                (EmailAddress.parseList(row.sender) + EmailAddress.parseList(row.recipients) + EmailAddress.parseList(row.cc ?? ""))
                    .contains { $0.normalized == normalized }
            }?.accountID
        }
    }
}
