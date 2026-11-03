import Foundation
import MailStore

extension FollowUpsModel {
    /// Snoozes attention to the commitment without changing any reply baseline.
    func deferAttention(_ entry: CommitmentEntry, until: Date?) async {
        guard entry.record.status == .open else { return }
        await mutate(entry, checkReminders: false) { store in
            _ = try await store.setCommitmentDeferral(accountID: entry.record.accountID, id: entry.record.id,
                until: until, expectedRevision: entry.record.revision, now: now())
        }
    }
}
