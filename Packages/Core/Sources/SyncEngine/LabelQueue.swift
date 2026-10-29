import Foundation
import GmailAPI
import MailStore

/// Why a label change can't be queued.
public enum LabelChangeError: Error, Sendable, Equatable {
    case name(LabelRules.NameProblem)
    /// The label isn't shown, or is one of Gmail's own.
    case notAUserLabel
}

extension ActionReceipt {
    /// The label a create queued: a temporary ID until Gmail creates it
    /// (`LabelRules.isTemporary`), then Gmail's.
    public var labelID: String? { actions.first?.labelID }
}

extension SyncEngine {
    // MARK: Queuing

    /// Queues a new label after the undo hold. Undo deletes it, unless Gmail
    /// turns out to have the label already: then Tern uses that label, and
    /// undo leaves it.
    public func createLabel(named name: String, color: LabelColor?) async throws -> ActionReceipt {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let row = try await write { tx in
            if let problem = LabelRules.problem(with: name, among: try tx.displayedLabels(accountID: accountID)) {
                throw LabelChangeError.name(problem)
            }
            return try tx.enqueueLabelChange(
                .createLabel, labelID: LabelRules.temporaryID(),
                change: .init(newName: name, newColor: color.map { .set(.init($0)) }),
                accountID: accountID, now: now, notBefore: notBefore
            )
        }
        scheduleSending()
        return register([row])
    }

    /// Renames a user label and the labels nested under it, each after its
    /// parent, under one undo. Nil when the name stays the same.
    public func renameLabel(_ labelID: String, to name: String) async throws -> ActionReceipt? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let rows = try await write { tx -> [PendingAction] in
            let labels = try tx.displayedLabels(accountID: accountID)
            let label = try Self.userLabel(labelID, among: labels, accountID: accountID, in: tx)
            guard name != label.name else { return [] }
            if let problem = LabelRules.problem(with: name, among: labels, renaming: label.id) {
                throw LabelChangeError.name(problem)
            }
            let children = LabelRules.renamedChildren(of: label.name, to: name, among: labels)
            for child in children {
                if let problem = LabelRules.problem(with: child.name, among: labels, renaming: child.label.id) {
                    throw LabelChangeError.name(problem)
                }
            }
            func rename(_ id: String, from oldName: String, to newName: String, after parentID: String?) throws -> PendingAction {
                try tx.enqueueLabelChange(
                    .updateLabel, labelID: id,
                    change: .init(newName: newName, oldName: oldName, parentLabelID: parentID),
                    accountID: accountID, now: now, notBefore: notBefore
                )
            }
            var rows = [try rename(label.id, from: label.name, to: name, after: nil)]
            var renamed = [(name: label.name, id: label.id)]
            for child in children {
                // The nearest renamed ancestor, so each label follows its own parent.
                let parent = renamed
                    .filter { child.label.name.hasPrefix($0.name + "/") }
                    .max { $0.name.count < $1.name.count }
                rows.append(try rename(child.label.id, from: child.label.name, to: child.name, after: parent?.id))
                renamed.append((child.label.name, child.label.id))
            }
            return rows
        }
        guard !rows.isEmpty else { return nil }
        scheduleSending()
        return register(rows)
    }

    /// Sets or removes a user label's color. Nil when it stays the same.
    public func setLabelColor(_ labelID: String, to color: LabelColor?) async throws -> ActionReceipt? {
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let row = try await write { tx -> PendingAction? in
            let label = try Self.userLabel(labelID, among: try tx.displayedLabels(accountID: accountID), accountID: accountID, in: tx)
            let old = Self.color(of: label)
            let new = color.map { PendingAction.LabelChange.Color($0) }
            guard new != old else { return nil }
            return try tx.enqueueLabelChange(
                .updateLabel, labelID: label.id,
                change: .init(newColor: new.map { .set($0) } ?? .remove, oldColor: old),
                accountID: accountID, now: now, notBefore: notBefore
            )
        }
        guard let row else { return nil }
        scheduleSending()
        return register([row])
    }

    /// Deletes a user label with no hold and no undo, since Gmail can't
    /// restore it. A label Gmail hasn't seen yet just leaves the queue.
    public func deleteLabel(_ labelID: String) async throws {
        let accountID = accountID
        let now = now()
        let dropped = try await write { tx -> [Int64] in
            let label = try Self.userLabel(labelID, among: try tx.displayedLabels(accountID: accountID), accountID: accountID, in: tx)
            let create = try tx.pendingActions(accountID: accountID).first { $0.kind == .createLabel && $0.labelID == label.id }
            if let create, create.state == .queued, create.attempts == 0 {
                return try tx.dropLabel(label.id, accountID: accountID)
            }
            _ = try tx.enqueueLabelChange(
                .deleteLabel, labelID: label.id, change: .init(deletedLabel: label),
                accountID: accountID, now: now, notBefore: now
            )
            return []
        }
        unavailableUndoIDs.formUnion(dropped)
        scheduleSending()
    }

    /// Adds and removes labels on conversations, one row per conversation
    /// under one undo. A label in both lists is only added.
    public func editLabels(threadIDs: [String], add: [String], remove: [String]) async throws -> ActionReceipt? {
        try await queueLabelEdits(threadIDs: threadIDs, add: add, remove: remove)
    }

    /// Moves conversations to `labelID`: adds it, and takes them out of the
    /// mailbox being viewed when that is the Inbox or a user label, or else
    /// out of the Inbox.
    public func move(threadIDs: [String], to labelID: String, from mailboxLabelID: String) async throws -> ActionReceipt? {
        try await queueLabelEdits(threadIDs: threadIDs, add: [labelID], remove: [], leaving: mailboxLabelID)
    }

    private func queueLabelEdits(
        threadIDs: [String], add: [String], remove: [String], leaving mailboxLabelID: String? = nil
    ) async throws -> ActionReceipt? {
        let threadIDs = threadIDs.removingDuplicates().sorted()
        guard !threadIDs.isEmpty else { return nil }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let rows = try await write { tx -> [PendingAction] in
            let resolve = { (ids: [String]) throws -> [String] in
                try ids.map { try tx.resolvedLabelID($0, accountID: accountID) }.removingDuplicates()
            }
            let add = try resolve(add)
            var remove = try resolve(remove)
            if let mailboxLabelID {
                let mailbox = try tx.resolvedLabelID(mailboxLabelID, accountID: accountID)
                let isUserLabel = try tx.displayedLabels(accountID: accountID).contains { $0.id == mailbox && !$0.isSystem }
                remove.append(mailbox == SystemLabel.inbox || isUserLabel ? mailbox : SystemLabel.inbox)
            }
            remove = remove.filter { !add.contains($0) }.removingDuplicates()
            guard !add.isEmpty || !remove.isEmpty else { return [] }
            return try threadIDs.map { threadID in
                try tx.enqueue(
                    .modifyThreads, accountID: accountID, threadIDs: [threadID],
                    add: add, remove: remove, now: now, notBefore: notBefore
                )
            }
        }
        guard !rows.isEmpty else { return nil }
        scheduleSending()
        return register(rows)
    }

    private static func userLabel(
        _ id: String, among labels: [LabelRecord], accountID: String, in tx: CacheTransaction
    ) throws -> LabelRecord {
        let id = try tx.resolvedLabelID(id, accountID: accountID)
        guard let label = labels.first(where: { $0.id == id }), !label.isSystem else { throw LabelChangeError.notAUserLabel }
        return label
    }

    private static func color(of label: LabelRecord) -> PendingAction.LabelChange.Color? {
        guard let text = label.textColor, let background = label.backgroundColor else { return nil }
        return .init(textColor: text, backgroundColor: background)
    }

    // MARK: Undo

    /// Undoes a label row and returns the IDs of rows that left the queue
    /// with it, whose own undo is then unavailable. A delete has no undo.
    static func undoLabelChange(_ action: PendingAction, accountID: String, now: Date, in tx: CacheTransaction) throws -> [Int64] {
        guard action.kind != .deleteLabel, let id = action.id else { return [] }
        guard let stored = try tx.action(id: id) else {
            try enqueueLabelInverse(of: action, accountID: accountID, now: now, in: tx)
            return []
        }
        switch stored.state {
        case .queued where stored.attempts == 0:
            // Gmail hasn't seen it. A create takes the changes that use it along.
            if stored.kind == .createLabel, let labelID = stored.labelID {
                return try tx.dropLabel(labelID, accountID: accountID)
            }
            try tx.deleteAction(id: id)
            return []
        case .undone:
            return []
        case .queued, .sending, .sent:
            // It may have reached Gmail. The inverse waits behind it, so undoing
            // a create sends the delete with Gmail's ID once that is known.
            try enqueueLabelInverse(of: stored, accountID: accountID, now: now, in: tx)
            return []
        }
    }

    /// Queues the reverse of a create or update with no hold.
    static func enqueueLabelInverse(of action: PendingAction, accountID: String, now: Date, in tx: CacheTransaction) throws {
        guard let original = action.labelID, let change = action.labelChange else { return }
        let labelID = try tx.resolvedLabelID(original, accountID: accountID)
        if LabelRules.isTemporary(labelID),
           try !tx.pendingActions(accountID: accountID).contains(where: { $0.kind == .createLabel && $0.labelID == labelID }) {
            // Its create is gone, so Gmail never had the label.
            return
        }
        switch action.kind {
        case .createLabel:
            // Gmail had the label before Tern asked for it, so it isn't Tern's to delete.
            guard change.adoptedExisting != true else { return }
            let label = try tx.displayedLabels(accountID: accountID).first { $0.id == labelID }
            _ = try tx.enqueueLabelChange(
                .deleteLabel, labelID: labelID, change: .init(deletedLabel: label),
                accountID: accountID, now: now, notBefore: now
            )
        case .updateLabel:
            var inverse = PendingAction.LabelChange(
                parentLabelID: try change.parentLabelID.map { try tx.resolvedLabelID($0, accountID: accountID) }
            )
            if let newName = change.newName, let oldName = change.oldName {
                inverse.newName = oldName
                inverse.oldName = newName
            }
            if let newColor = change.newColor {
                inverse.newColor = change.oldColor.map { .set($0) } ?? .remove
                if case .set(let color) = newColor { inverse.oldColor = color }
            }
            guard inverse.newName != nil || inverse.newColor != nil else { return }
            _ = try tx.enqueueLabelChange(
                .updateLabel, labelID: labelID, change: inverse, accountID: accountID, now: now, notBefore: now
            )
        default:
            return
        }
    }

    // MARK: Sending

    /// Puts Gmail's ID in place of a temporary one, and takes out a temporary
    /// ID whose create is gone, so none reaches Gmail. A claimed row may still
    /// carry one when an undo was built from an old receipt. Nil when the row
    /// has nothing left to send and was deleted.
    static func resolvingTemporaryLabels(_ row: PendingAction, accountID: String, in tx: CacheTransaction) throws -> PendingAction? {
        guard row.kind != .createLabel, let id = row.id else { return row }
        let ids = [row.labelID, row.labelChange?.parentLabelID].compactMap { $0 } + row.addLabelIDs + row.removeLabelIDs
        guard ids.contains(where: LabelRules.isTemporary) else { return row }
        func resolve(_ id: String) throws -> String? {
            let resolved = try tx.resolvedLabelID(id, accountID: accountID)
            return LabelRules.isTemporary(resolved) ? nil : resolved
        }
        var resolved = row
        if row.kind.changesLabel {
            guard let labelID = try row.labelID.flatMap(resolve) else {
                try tx.deleteLabelChange(id: id, accountID: accountID)
                return nil
            }
            resolved.labelID = labelID
            if var change = resolved.labelChange {
                change.parentLabelID = try change.parentLabelID.flatMap(resolve)
                resolved.labelChange = change
            }
        } else {
            resolved.addLabelIDs = try row.addLabelIDs.compactMap(resolve)
            resolved.removeLabelIDs = try row.removeLabelIDs.compactMap(resolve)
            resolved.diff = try row.diff.mapValues {
                .init(added: try $0.added.compactMap(resolve), removed: try $0.removed.compactMap(resolve))
            }
            // As in `dropLabel`: a move into a label Gmail never had goes whole.
            if resolved.addLabelIDs.count < row.addLabelIDs.count
                || (resolved.addLabelIDs.isEmpty && resolved.removeLabelIDs.isEmpty) {
                try tx.deleteAction(id: id)
                return nil
            }
        }
        try tx.updateAction(resolved)
        return resolved
    }

    /// Sends one label row on its own and records what Gmail answered.
    func sendLabelChange(_ row: PendingAction) async {
        guard !isStopped, !Task.isCancelled else { return }
        guard let labelID = row.labelID, let change = row.labelChange, Self.hasAllowedColor(change) else {
            return await refuseLabelChange(row)
        }
        do {
            switch row.kind {
            case .createLabel:
                guard let name = change.newName else { return await refuseLabelChange(row) }
                // An earlier attempt may have created it without Tern hearing back.
                if row.attempts > 1, let existing = try await existingLabelID(named: name) {
                    return await recordCreated(row, realID: existing)
                }
                let label = try await gmail.createLabel(name: name, color: Self.labelColor(change.newColor))
                await recordCreated(row, realID: label.id)
            case .updateLabel:
                _ = try await gmail.patchLabel(id: labelID, name: change.newName, color: Self.colorChange(change.newColor))
                await finish(row, outcome: .sent)
            case .deleteLabel:
                do {
                    try await gmail.deleteLabel(id: labelID)
                } catch GmailError.notFound {
                    // Already gone, which is what the delete wanted.
                }
                await recordDeleted(row)
            default:
                return
            }
        } catch {
            if row.kind == .createLabel, let error = error as? GmailError, Self.isRefusal(error), let name = change.newName {
                // Gmail refused the name, perhaps because the label exists already.
                let existing: String?
                do {
                    existing = try await existingLabelID(named: name)
                } catch {
                    return await finish(row, outcome: .retry(String(describing: error)))
                }
                if let existing { return await recordCreated(row, realID: existing, adopted: true) }
                return await refuseLabelChange(row)
            }
            if case .retry(let reason) = Self.outcome(for: error) {
                await finish(row, outcome: .retry(reason))
            } else {
                await refuseLabelChange(row)
            }
        }
    }

    /// A definite answer about the request, as opposed to a rate limit,
    /// sign-in, server or network error, after which a retry may succeed.
    private static func isRefusal(_ error: GmailError) -> Bool {
        switch error {
        case .http(let status, _): [400, 403, 409].contains(status)
        case .invalidRequest: true
        default: false
        }
    }

    private func existingLabelID(named name: String) async throws -> String? {
        let key = name.lowercased()
        return try await gmail.labels().first { !$0.isSystem && $0.name.lowercased() == key }?.id
    }

    /// Records Gmail's ID for a created label, swaps it into queued rows and
    /// live receipts, and marks the create sent, all in one write. `adopted`
    /// marks a label Gmail had before, which undo leaves in Gmail; a delete
    /// an undo queued while the request was out goes too.
    private func recordCreated(_ row: PendingAction, realID: String, adopted: Bool = false) async {
        guard let id = row.id, let temporaryID = row.labelID else { return }
        let accountID = accountID
        let now = now()
        let result = try? await write { tx -> (changed: [PendingAction], keptDeletes: [Int64]) in
            var keptDeletes: [Int64] = []
            if adopted {
                for delete in try tx.pendingActions(accountID: accountID)
                where delete.kind == .deleteLabel && delete.labelID == temporaryID && delete.state == .queued {
                    guard let deleteID = delete.id else { continue }
                    try tx.deleteLabelChange(id: deleteID, accountID: accountID)
                    keptDeletes.append(deleteID)
                }
            }
            var changed = try tx.recordCreatedLabel(temporaryID: temporaryID, realID: realID, accountID: accountID)
            guard var created = try tx.action(id: id) else { return (changed, keptDeletes) }
            created.state = .sent
            created.sentAt = now
            created.lastError = nil
            if adopted { created.labelChange?.adoptedExisting = true }
            try tx.updateAction(created)
            changed.removeAll { $0.id == id }
            changed.append(created)
            return (changed, keptDeletes)
        }
        guard let result else { return }
        for row in result.changed {
            if let id = row.id { undoReceipts[id]?.value?.update(row) }
        }
        if !result.keptDeletes.isEmpty {
            unavailableUndoIDs.formUnion(result.keptDeletes)
            continuation.yield(.actionFailed(Self.adoptedLabelNotice(named: row.labelChange?.newName)))
        }
    }

    /// For undoing a create that took a label Gmail had already.
    static func adoptedLabelNotice(named name: String?) -> String {
        "“\(name ?? "")” was already a label in Gmail, so Tern kept it."
    }

    /// Marks a delete sent and takes the label out of the cache.
    private func recordDeleted(_ row: PendingAction) async {
        guard let id = row.id, let labelID = row.labelID else { return }
        let accountID = accountID
        let now = now()
        let dropped = try? await write { tx -> [Int64] in
            guard var deleted = try tx.action(id: id) else { return [] }
            deleted.state = .sent
            deleted.sentAt = now
            deleted.lastError = nil
            try tx.updateAction(deleted)
            return try tx.dropLabel(labelID, accountID: accountID)
        }
        unavailableUndoIDs.formUnion(dropped ?? [])
    }

    /// Gmail refused the row for good. A create leaves with the changes that
    /// use the label, a delete puts the label back, and an update just goes.
    private func refuseLabelChange(_ row: PendingAction) async {
        guard let id = row.id else { return }
        let accountID = accountID
        let dropped = try? await write { tx -> [Int64] in
            try tx.deleteLabelChange(id: id, accountID: accountID)
            guard row.kind == .createLabel, let labelID = row.labelID else { return [id] }
            return try [id] + tx.dropLabel(labelID, accountID: accountID)
        }
        guard let dropped else { return }
        unavailableUndoIDs.formUnion(dropped)
        continuation.yield(.actionFailed(Self.refusalMessage(for: row)))
    }

    private static func refusalMessage(for row: PendingAction) -> String {
        switch row.kind {
        case .createLabel:
            "Gmail didn't create the label “\(row.labelChange?.newName ?? "")”."
        case .deleteLabel:
            "Gmail didn't delete the label “\(row.labelChange?.deletedLabel?.name ?? "")”, so Tern put it back."
        default:
            "Gmail didn't accept a label change, so Tern put the label back."
        }
    }

    // MARK: Colors

    /// Whether a color the row sets is one Gmail allows. Rows are built from
    /// `LabelColor`, but an undo restores whatever color Gmail listed before.
    private static func hasAllowedColor(_ change: PendingAction.LabelChange) -> Bool {
        guard case .set(let color)? = change.newColor else { return true }
        return LabelColor(backgroundColor: color.backgroundColor, textColor: color.textColor) != nil
    }

    private static func labelColor(_ change: PendingAction.LabelChange.ColorChange?) -> LabelColor? {
        guard case .set(let color)? = change else { return nil }
        return LabelColor(backgroundColor: color.backgroundColor, textColor: color.textColor)
    }

    private static func colorChange(_ change: PendingAction.LabelChange.ColorChange?) -> LabelColorChange? {
        switch change {
        case .set?: labelColor(change).map { .set($0) }
        case .remove?: .remove
        case nil: nil
        }
    }
}

extension PendingAction.LabelChange.Color {
    init(_ color: LabelColor) {
        self.init(textColor: color.textColor, backgroundColor: color.backgroundColor)
    }
}
