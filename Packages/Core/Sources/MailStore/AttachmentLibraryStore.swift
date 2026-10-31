import Foundation
import GRDB

extension MailCache {
    public func attachmentLibrary(query: AttachmentLibraryQuery) async throws -> AttachmentLibraryPage {
        try await read { try $0.attachmentLibrary(query: query) }
    }

    public func observeAttachmentLibrary(query: AttachmentLibraryQuery) -> AsyncThrowingStream<AttachmentLibraryPage, any Error> {
        observe { try CacheTransaction(db: $0).attachmentLibrary(query: query) }
    }

    public func attachmentIndexStates(accountIDs: [String]) -> AsyncThrowingStream<[AttachmentIndexState], any Error> {
        observe { db in
            try AttachmentIndexState.filter(accountIDs.contains(Column("accountID")))
                .order(Column("accountID")).fetchAll(db)
        }
    }
}

extension CacheTransaction {
    /// Replaces one email's files while retaining user categories and ignoring stale provider versions.
    /// The caller commits the page checkpoint in the same transaction.
    public func replaceLibraryAttachments(
        _ attachments: [AttachmentRecord], message: MessageRecord, labelIDs: [String], generation: String? = nil
    ) throws {
        let stored = try libraryAttachments(messageID: message.id, accountID: message.accountID)
        if let latest = stored.map(\.historyID).max(), latest > message.historyID {
            if let generation {
                try db.execute(sql: "UPDATE attachmentLibrary SET generation = ? WHERE accountID = ? AND messageID = ?",
                    arguments: [generation, message.accountID, message.id])
            }
            return
        }
        let old = Dictionary(stored.map { ($0.partID, $0) }, uniquingKeysWith: { first, _ in first })
        let eligible = attachments.filter { !$0.isInline && $0.accountID == message.accountID && $0.messageID == message.id }
        let parts = Set(eligible.map(\.partID))
        try AttachmentLibraryItem.filter(Column("accountID") == message.accountID && Column("messageID") == message.id)
            .filter(!parts.contains(Column("partID"))).deleteAll(db)
        for attachment in eligible {
            let previous = old[attachment.partID]
            var item = AttachmentLibraryItem(attachment: attachment, threadID: message.threadID, sender: message.sender,
                subject: message.subject, date: message.date, labelIDs: labelIDs,
                historyID: message.historyID, generation: generation ?? previous?.generation)
            if let previous {
                if previous.categorySource == .manual || previous.matchesClassificationInput(item) {
                    item.category = previous.category
                    item.categorySource = previous.categorySource
                }
                if previous.matchesClassificationInput(item) {
                    item.contentClassificationVersion = previous.contentClassificationVersion
                    item.classificationRetryAfter = previous.classificationRetryAfter
                }
            }
            try item.upsert(db)
        }
        try replaceLibraryLabels(eligible.isEmpty ? [] : labelIDs, messageID: message.id, accountID: message.accountID)
    }

    public func libraryAttachments(messageID: String, accountID: String) throws -> [AttachmentLibraryItem] {
        try AttachmentLibraryItem.filter(Column("accountID") == accountID && Column("messageID") == messageID)
            .order(Column("partID")).fetchAll(db)
    }

    public func libraryAttachment(accountID: String, messageID: String, partID: String) throws -> AttachmentLibraryItem? {
        try AttachmentLibraryItem.fetchOne(db, key: ["accountID": accountID, "messageID": messageID, "partID": partID])
    }

    /// Use only for provider deletions. Ordinary message-cache eviction must retain the library.
    public func deleteLibraryAttachments(messageIDs: [String], accountID: String) throws {
        for messageID in Set(messageIDs) {
            try AttachmentLibraryItem.filter(Column("accountID") == accountID && Column("messageID") == messageID).deleteAll(db)
            try replaceLibraryLabels([], messageID: messageID, accountID: accountID)
        }
    }

    public func setAttachmentCategory(_ category: AttachmentCategory, accountID: String, messageID: String, partID: String) throws {
        try db.execute(sql: "UPDATE attachmentLibrary SET category = ?, categorySource = 'manual', classificationRetryAfter = NULL WHERE accountID = ? AND messageID = ? AND partID = ?",
            arguments: [category.rawValue, accountID, messageID, partID])
    }

    public func attachmentIndexState(accountID: String) throws -> AttachmentIndexState? {
        try AttachmentIndexState.fetchOne(db, key: accountID)
    }

    public func saveAttachmentIndexState(_ state: AttachmentIndexState) throws { try state.upsert(db) }

    /// Called only after every page of a fresh enumeration has committed.
    public func finishLibraryGeneration(accountID: String, generation: String) throws {
        try db.execute(sql: "DELETE FROM attachmentLibrary WHERE accountID = ? AND (generation IS NULL OR generation != ?)",
            arguments: [accountID, generation])
        try db.execute(sql: """
            DELETE FROM attachmentLibraryLabel WHERE accountID = ? AND NOT EXISTS (
                SELECT 1 FROM attachmentLibrary a WHERE a.accountID = attachmentLibraryLabel.accountID
                    AND a.messageID = attachmentLibraryLabel.messageID)
            """, arguments: [accountID])
    }

    public func applyLibraryLabelChange(
        messageID: String, added: [String], removed: [String], historyID: Int64, accountID: String
    ) throws {
        let items = try libraryAttachments(messageID: messageID, accountID: accountID)
        guard let first = items.first, first.historyID <= historyID else { return }
        let labels = Set(first.labelIDs).union(added).subtracting(removed).sorted()
        for var item in items {
            item.labelIDs = labels
            item.historyID = historyID
            try item.update(db)
        }
        try replaceLibraryLabels(labels, messageID: messageID, accountID: accountID)
    }

    /// Mail sync can refresh metadata for files already indexed without fetching their payload.
    func updateLibraryMetadata(_ message: MessageRecord, labelIDs: [String]) throws {
        // Migration fixtures and upgrade helpers can write messages before this migration exists.
        guard try db.tableExists(AttachmentLibraryItem.databaseTableName) else { return }
        let items = try libraryAttachments(messageID: message.id, accountID: message.accountID)
        guard !items.isEmpty else { return }
        try replaceLibraryAttachments(items.map(\.attachment), message: message, labelIDs: labelIDs)
    }

    private func replaceLibraryLabels(_ labels: [String], messageID: String, accountID: String) throws {
        try db.execute(sql: "DELETE FROM attachmentLibraryLabel WHERE accountID = ? AND messageID = ?", arguments: [accountID, messageID])
        for label in Set(labels) {
            try db.execute(sql: "INSERT INTO attachmentLibraryLabel (accountID,messageID,labelID) VALUES (?,?,?)",
                arguments: [accountID, messageID, label])
        }
    }

    public func attachmentLibrary(query: AttachmentLibraryQuery) throws -> AttachmentLibraryPage {
        guard !query.accountIDs.isEmpty else { return .init(items: [], totalCount: 0, hasMore: false) }
        let accounts = Array(Set(query.accountIDs)).sorted()
        let placeholders = Array(repeating: "?", count: accounts.count).joined(separator: ",")
        var predicates = ["a.accountID IN (\(placeholders))"]
        var arguments = StatementArguments(accounts)
        func add(_ predicate: String, _ argument: any DatabaseValueConvertible) {
            predicates.append(predicate)
            arguments += StatementArguments([argument])
        }
        for term in AttachmentLibraryItem.searchNormalized(query.search).split(whereSeparator: \.isWhitespace) {
            add("a.searchText LIKE ? ESCAPE '\\'", "%\(Self.libraryLike(String(term)))%")
        }
        let sender = AttachmentLibraryItem.searchNormalized(query.sender.trimmingCharacters(in: .whitespacesAndNewlines))
        if !sender.isEmpty { add("a.senderSearch LIKE ? ESCAPE '\\'", "%\(Self.libraryLike(sender))%") }
        if let start = query.startDate { add("a.date >= ?", start) }
        if let end = query.endDate { add("a.date < ?", end) }
        if let fileExtension = query.fileExtension { add("a.fileExtension = ?", fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        if let category = query.category { add("a.category = ?", category.rawValue) }
        if let size = query.minimumSize { add("a.size >= ?", max(0, size)) }
        if let size = query.maximumSize { add("a.size <= ?", size) }
        if let label = query.label {
            add("a.accountID = ?", label.accountID)
            add("EXISTS (SELECT 1 FROM attachmentLibraryLabel l WHERE l.accountID = a.accountID AND l.messageID = a.messageID AND l.labelID = ?)", label.id)
        }
        let condition = predicates.joined(separator: " AND ")
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachmentLibrary a WHERE \(condition)", arguments: arguments) ?? 0
        let order: String
        switch query.sort {
        case .newest: order = "a.date DESC"
        case .oldest: order = "a.date ASC"
        case .filename: order = "a.filename COLLATE NOCASE ASC"
        case .sender: order = "a.sender COLLATE NOCASE ASC"
        case .largest: order = "a.size DESC"
        case .smallest: order = "a.size ASC"
        }
        let offset = max(0, query.offset)
        let limit = max(1, min(query.limit, 500))
        let items = try AttachmentLibraryItem.fetchAll(db, sql: """
            SELECT a.* FROM attachmentLibrary a WHERE \(condition)
            ORDER BY \(order), a.accountID, a.messageID, a.partID LIMIT ? OFFSET ?
            """, arguments: arguments + [limit, offset])
        return .init(items: items, totalCount: total, hasMore: offset + items.count < total)
    }

    private static func libraryLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
