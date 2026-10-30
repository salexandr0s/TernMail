import Foundation
import GRDB

extension AccountStore {
    public func listIdentityChanges(accountIDs: [String]) -> AsyncThrowingStream<[IdentityRecord], any Error> {
        let values = ValueObservation.tracking { db in
            guard !accountIDs.isEmpty else { return [IdentityRecord]() }
            let placeholders = Array(repeating: "?", count: accountIDs.count).joined(separator: ",")
            return try IdentityRecord.fetchAll(db, sql: "SELECT * FROM sendAsIdentity WHERE accountID IN (\(placeholders))", arguments: StatementArguments(accountIDs))
        }.removeDuplicates().values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await identities in values { continuation.yield(identities) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Invalidates navigation when names, order, scope or account ownership change.
    public func mailNavigationChanges() -> AsyncThrowingStream<UUID, any Error> {
        let values = ValueObservation.tracking { db in
            _ = try Row.fetchAll(db, sql: "SELECT * FROM mailFavorite")
            _ = try Row.fetchAll(db, sql: "SELECT * FROM mailFavoriteAccount")
            _ = try Row.fetchAll(db, sql: "SELECT * FROM mailSavedSearch")
            _ = try Row.fetchAll(db, sql: "SELECT * FROM mailSavedSearchAccount")
            return UUID()
        }.values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await revision in values { continuation.yield(revision) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
