import Foundation
import GRDB

extension CacheTransaction {
    /// Takes back a send request Gmail never received, so the send waiting
    /// to retry can be cancelled again (`canCancelPendingExit`).
    public func withdrawSendRequest(localDraftID: String) throws {
        guard var draft = try localDraft(id: localDraftID), draft.sendRequested else { return }
        draft.sendRequested = false
        try draft.update(db)
    }

    /// `currentLabels(threadID:accountID:)` for each conversation, reading
    /// the queue once for all of them.
    public func currentLabels(threadIDs: some Sequence<String>, accountID: String) throws -> [String: [String: Set<String>]] {
        let actions = try pendingActions(accountID: accountID)
        var labels: [String: [String: Set<String>]] = [:]
        for threadID in threadIDs where labels[threadID] == nil {
            labels[threadID] = try effectiveLabels(threadID: threadID, accountID: accountID, actions: actions)
        }
        return labels
    }
}
