import GRDB

extension AccountStore {
    /// Follows configuration edits without restarting the account's mailbox.
    public func accountChanges(id: String) -> AsyncThrowingStream<AccountRecord?, any Error> {
        let values = ValueObservation.tracking { db in
            try AccountRecord.fetchOne(db, key: id)
        }.removeDuplicates().values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await record in values { continuation.yield(record) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
