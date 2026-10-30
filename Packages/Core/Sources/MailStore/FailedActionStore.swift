import Foundation
import GRDB

public enum FailedActionError: Error, Sendable, Equatable {
    case notFound
    case draftMissing
    case conflictingWork
}

extension MailCache {
    public func failedActions(accountIDs: [String]) -> AsyncThrowingStream<[PendingAction], any Error> {
        observe { db in
            try PendingAction.filter(accountIDs.contains(Column("accountID")) && Column("state") == PendingAction.State.failed.rawValue)
                .order(Column("id").desc).fetchAll(db)
        }
    }
}

extension CacheTransaction {
    public func failedActions(accountID: String) throws -> [PendingAction] {
        try PendingAction.filter(Column("accountID") == accountID && Column("state") == PendingAction.State.failed.rawValue)
            .order(Column("id")).fetchAll(db)
    }

    public func retainFailedAction(_ action: PendingAction, message: String) throws {
        guard let id = action.id, let stored = try self.action(id: id), stored.state != .undone else { return }
        var failed = action
        failed.state = .failed
        failed.lastError = message
        failed.sentAt = nil
        try failed.update(db)
        var threads = Set(failed.threadIDs).union(try threadIDsOf(messageIDs: failed.messageIDs, accountID: failed.accountID))
        if failed.kind == .deleteLabel, let labelID = failed.labelID {
            threads.formUnion(try threadIDsCarrying(labelID, accountID: failed.accountID))
        }
        try rebuildThreads(threads, accountID: failed.accountID)
    }

    /// Reactivate the same durable intent; a second Retry cannot duplicate it.
    public func retryFailedAction(id: Int64, accountID: String, now: Date) throws -> Bool {
        guard var row = try action(id: id), row.accountID == accountID else { throw FailedActionError.notFound }
        guard row.state == .failed else { return false }
        let active = try pendingActions(accountID: accountID).filter { $0.state == .queued || $0.state == .sending }
        var affectedThreads = Set(row.threadIDs).union(try threadIDsOf(messageIDs: row.messageIDs, accountID: accountID))
        if row.kind != .createLabel {
            let labels = [row.labelID, row.labelChange?.parentLabelID].compactMap { $0 } + row.addLabelIDs + row.removeLabelIDs
            for labelID in labels where LabelRules.isTemporary(labelID) {
                if try resolvedLabelID(labelID, accountID: accountID) == labelID,
                   !active.contains(where: { $0.kind == .createLabel && $0.labelID == labelID }) {
                    throw FailedActionError.conflictingWork
                }
            }
        }
        if let draftID = row.localDraftID {
            guard var draft = try localDraft(id: draftID), draft.accountID == accountID else { throw FailedActionError.draftMissing }
            guard !active.contains(where: { $0.localDraftID == draftID }) else { throw FailedActionError.conflictingWork }
            affectedThreads.formUnion(draft.threadID.map { [$0] } ?? [])
            affectedThreads.formUnion(try threadIDsOf(messageIDs: [draft.sourceMessageID, draft.savedMessageID].compactMap { $0 }, accountID: accountID))
            switch row.kind {
            case .sendDraft: draft.state = .sending
            case .discardDraft: draft.state = .discarding
            default: draft.state = .editing
            }
            draft.sendError = nil
            draft.updatedAt = now
            try draft.update(db)
        }
        if row.settingsChange != nil, active.contains(where: { $0.settingsChange != nil }) {
            throw FailedActionError.conflictingWork
        }
        row.state = .queued
        row.notBefore = now
        row.lastError = nil
        try row.update(db)
        try rebuildThreads(affectedThreads, accountID: accountID)
        return true
    }

    public func discardFailedAction(id: Int64, accountID: String) throws {
        guard let row = try action(id: id), row.accountID == accountID, row.state == .failed else { return }
        try deleteAction(id: id)
    }
}
