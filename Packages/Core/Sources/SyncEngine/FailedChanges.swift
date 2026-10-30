import Foundation
import GmailAPI
import MailStore

extension SyncEngine {
    @discardableResult
    public func retryFailedAction(id: Int64) async throws -> Bool {
        let accountID = accountID
        let now = now()
        let retried = try await write { tx in try tx.retryFailedAction(id: id, accountID: accountID, now: now) }
        if retried {
            unavailableUndoIDs.remove(id)
            scheduleSending()
        }
        return retried
    }

    public func discardFailedAction(id: Int64) async throws {
        let accountID = accountID
        try await write { tx in try tx.discardFailedAction(id: id, accountID: accountID) }
    }
}
