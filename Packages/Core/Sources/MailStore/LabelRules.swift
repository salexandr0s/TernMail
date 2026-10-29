import Foundation
import GRDB

/// Rules for user labels: names, temporary IDs, and the labels to show with
/// queued changes applied.
public enum LabelRules {
    /// A label's ID starts with this until Gmail creates the label.
    public static let temporaryPrefix = "TERN_PENDING_"

    public static func temporaryID() -> String { temporaryPrefix + UUID().uuidString }

    public static func isTemporary(_ id: String) -> Bool { id.hasPrefix(temporaryPrefix) }

    public enum NameProblem: Error, Sendable, Equatable {
        /// Empty, or with an empty part between slashes.
        case empty
        /// A system label's name, which Gmail refuses.
        case reserved
        /// Another label has it, ignoring case.
        case taken
    }

    /// Names Gmail keeps for its own labels, lowercased.
    static let reservedNames: Set<String> = [
        "inbox", "sent", "draft", "drafts", "spam", "trash", "starred", "important",
        "unread", "chat", "chats", "all mail",
    ]

    /// Why `name` can't be a label's full name, or nil when it can. `labels`
    /// are the labels shown now; `labelID` is the label being renamed, which
    /// may keep its own name in another case.
    public static func problem(with name: String, among labels: [LabelRecord], renaming labelID: String? = nil) -> NameProblem? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return .empty }
        let key = name.lowercased()
        if reservedNames.contains(key) || labels.contains(where: { $0.isSystem && $0.name.lowercased() == key }) {
            return .reserved
        }
        if labels.contains(where: { $0.id != labelID && $0.name.lowercased() == key }) { return .taken }
        return nil
    }

    /// The labels nested under `oldName` and their names once it becomes
    /// `newName`, parents before children.
    public static func renamedChildren(
        of oldName: String, to newName: String, among labels: [LabelRecord]
    ) -> [(label: LabelRecord, name: String)] {
        let prefix = oldName + "/"
        return labels
            .filter { !$0.isSystem && $0.name.hasPrefix(prefix) }
            .sorted { $0.name.count < $1.name.count }
            .map { ($0, newName + "/" + $0.name.dropFirst(prefix.count)) }
    }

    /// Gmail's labels as last listed, with queued, sending and sent label rows
    /// applied in order, sorted by name. A sent row stays until a sync pass
    /// that started after it commits, so a listing fetched before the change
    /// reached Gmail can't undo it.
    static func displayed(_ labels: [LabelRecord], applying rows: [PendingAction]) -> [LabelRecord] {
        var result = labels
        for row in rows where row.kind.changesLabel {
            guard let id = row.labelID, let change = row.labelChange else { continue }
            let index = result.firstIndex { $0.id == id }
            switch row.kind {
            case .createLabel:
                guard index == nil else { continue }
                var label = LabelRecord(accountID: row.accountID, id: id, name: change.newName ?? "", isSystem: false)
                apply(change.newColor, to: &label)
                result.append(label)
            case .updateLabel:
                guard let index else { continue }
                if let name = change.newName { result[index].name = name }
                apply(change.newColor, to: &result[index])
            case .deleteLabel:
                result.removeAll { $0.id == id }
            default:
                continue
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func apply(_ change: PendingAction.LabelChange.ColorChange?, to label: inout LabelRecord) {
        switch change {
        case .set(let color)?:
            label.textColor = color.textColor
            label.backgroundColor = color.backgroundColor
        case .remove?:
            label.textColor = nil
            label.backgroundColor = nil
        case nil:
            break
        }
    }
}

extension CacheTransaction {
    /// The account's labels as the sidebar and pickers show them.
    public func displayedLabels(accountID: String) throws -> [LabelRecord] {
        LabelRules.displayed(try labels(accountID: accountID), applying: try pendingActions(accountID: accountID))
    }

    /// Queues a create, update or delete row for `labelID`. A delete takes the
    /// label off its conversations at once.
    public func enqueueLabelChange(
        _ kind: PendingAction.Kind,
        labelID: String,
        change: PendingAction.LabelChange,
        accountID: String,
        now: Date,
        notBefore: Date
    ) throws -> PendingAction {
        var row = PendingAction(
            id: nil, accountID: accountID, kind: kind,
            threadIDs: [], messageIDs: [], addLabelIDs: [], removeLabelIDs: [], diff: [:],
            state: .queued, attempts: 0, lastError: nil,
            createdAt: now, notBefore: notBefore, sentAt: nil,
            labelID: try resolvedLabelID(labelID, accountID: accountID),
            labelChange: change
        )
        try row.insert(db)
        if kind == .deleteLabel, let id = row.labelID {
            try rebuildThreads(try threadIDsListed(under: id, accountID: accountID), accountID: accountID)
        }
        return row
    }

    /// Gmail's ID for a label created under a temporary ID, or `id` itself.
    public func resolvedLabelID(_ id: String, accountID: String) throws -> String {
        guard LabelRules.isTemporary(id) else { return id }
        return try String.fetchOne(
            db, sql: "SELECT realID FROM labelAlias WHERE accountID = ? AND temporaryID = ?", arguments: [accountID, id]
        ) ?? id
    }

    /// Records Gmail's ID for a label created under `temporaryID` and puts it
    /// in every row that names the temporary one. Returns the rows changed.
    public func recordCreatedLabel(temporaryID: String, realID: String, accountID: String) throws -> [PendingAction] {
        try db.execute(
            sql: "INSERT OR REPLACE INTO labelAlias (accountID, temporaryID, realID) VALUES (?, ?, ?)",
            arguments: [accountID, temporaryID, realID]
        )
        let swap = { (id: String) in id == temporaryID ? realID : id }
        var changed: [PendingAction] = []
        var threads = Set<String>()
        for var row in try pendingActions(accountID: accountID) {
            let before = row
            row.labelID = row.labelID.map(swap)
            if var change = row.labelChange {
                change.parentLabelID = change.parentLabelID.map(swap)
                row.labelChange = change
            }
            row.addLabelIDs = row.addLabelIDs.map(swap)
            row.removeLabelIDs = row.removeLabelIDs.map(swap)
            row.diff = row.diff.mapValues { .init(added: $0.added.map(swap), removed: $0.removed.map(swap)) }
            guard row != before else { continue }
            try row.update(db)
            changed.append(row)
            threads.formUnion(row.threadIDs)
            threads.formUnion(try threadIDsOf(messageIDs: row.messageIDs, accountID: accountID))
        }
        try rebuildThreads(threads, accountID: accountID)
        return changed
    }

    /// Aliases matter only while a receipt or an open picker may still hold
    /// a temporary ID, so a launch starts without them.
    public func clearLabelAliases(accountID: String) throws {
        try db.execute(sql: "DELETE FROM labelAlias WHERE accountID = ?", arguments: [accountID])
    }

    /// Takes a label that's gone, or that Gmail never created, out of the
    /// cache: off its messages, out of queued rows (deleting the label's own
    /// queued rows and conversation rows left with nothing to change), and off
    /// the conversations. A conversation row that adds a label Gmail never
    /// had is deleted whole, so a move into it doesn't leave the conversation
    /// out of its mailbox with no label. Returns the IDs of the rows deleted.
    @discardableResult
    public func dropLabel(_ labelID: String, accountID: String) throws -> [Int64] {
        var threads = try threadIDsListed(under: labelID, accountID: accountID)
        threads.formUnion(try threadIDsCarrying(labelID, accountID: accountID))
        try db.execute(sql: "DELETE FROM messageLabel WHERE accountID = ? AND labelID = ?", arguments: [accountID, labelID])

        let neverCreated = LabelRules.isTemporary(labelID)
        var deleted: [Int64] = []
        for var row in try pendingActions(accountID: accountID) where row.state == .queued {
            if row.kind.changesLabel {
                guard row.labelID == labelID else { continue }
                try row.delete(db)
                deleted += row.id.map { [$0] } ?? []
                continue
            }
            guard (row.addLabelIDs + row.removeLabelIDs).contains(labelID) else { continue }
            threads.formUnion(row.threadIDs)
            threads.formUnion(try threadIDsOf(messageIDs: row.messageIDs, accountID: accountID))
            let dropsWhole = neverCreated && row.addLabelIDs.contains(labelID)
            row.addLabelIDs.removeAll { $0 == labelID }
            row.removeLabelIDs.removeAll { $0 == labelID }
            row.diff = row.diff.mapValues {
                .init(added: $0.added.filter { $0 != labelID }, removed: $0.removed.filter { $0 != labelID })
            }
            if dropsWhole || (row.addLabelIDs.isEmpty && row.removeLabelIDs.isEmpty) {
                try row.delete(db)
                deleted += row.id.map { [$0] } ?? []
            } else {
                try row.update(db)
            }
        }
        try rebuildThreads(threads, accountID: accountID)
        return deleted
    }

    /// Removes a label row. The conversations a queued delete took the label
    /// off get it back.
    public func deleteLabelChange(id: Int64, accountID: String) throws {
        guard let row = try action(id: id) else { return }
        try row.delete(db)
        guard row.kind == .deleteLabel, let labelID = row.labelID else { return }
        var threads = try threadIDsCarrying(labelID, accountID: accountID)
        for use in try pendingActions(accountID: accountID) where (use.addLabelIDs + use.removeLabelIDs).contains(labelID) {
            threads.formUnion(use.threadIDs)
            threads.formUnion(try threadIDsOf(messageIDs: use.messageIDs, accountID: accountID))
        }
        try rebuildThreads(threads, accountID: accountID)
    }

    /// Conversations with a message that has the label on Gmail.
    func threadIDsCarrying(_ labelID: String, accountID: String) throws -> Set<String> {
        try String.fetchSet(db, sql: """
            SELECT message.threadID FROM messageLabel
            JOIN message ON message.accountID = messageLabel.accountID AND message.id = messageLabel.messageID
            WHERE messageLabel.accountID = ? AND messageLabel.labelID = ?
            """, arguments: [accountID, labelID])
    }

    private func threadIDsListed(under labelID: String, accountID: String) throws -> Set<String> {
        try String.fetchSet(
            db, sql: "SELECT threadID FROM threadLabel WHERE accountID = ? AND labelID = ?", arguments: [accountID, labelID]
        )
    }
}
