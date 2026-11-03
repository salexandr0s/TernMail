import Foundation
import GRDB
import Testing
@testable import MailStore

private let clock = Date(timeIntervalSince1970: 1_900_000_000)

@Suite struct CommitmentStoreTests {
    @Test func acceptedWorkSurvivesCacheResetAndReopeningConfig() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.sqlite")
        let store = try AccountStore.open(at: url)
        try await seedAccount(store, "a")
        let record = commitment()
        let saved = try await store.createCommitment(record, reminders: [reminder(record)])
        let cache = try MailCache.inMemory()
        try await cache.resetDisposableCache()

        let reopened = try AccountStore.open(at: url)
        #expect(try await reopened.commitmentEntries(accountIDs: ["a"]) == [saved])
        #expect(saved.record.sourceSubject == "Proposal")
        #expect(saved.reminders.count == 1)
    }

    @Test func accountScopesCleanupAndObservationKeepRecordsIsolated() async throws {
        let store = try await configuredStore()
        try await seedAccount(store, "b")
        for account in ["a", "b"] {
            let record = commitment(account: account)
            _ = try await store.createCommitment(record, reminders: [reminder(record)])
        }
        var changes = store.observeCommitments(accountIDs: ["a"]).makeAsyncIterator()
        let first = try #require(try await changes.next())
        #expect(first.count == 1)
        #expect(first.first?.record.accountID == "a")
        #expect(try await store.commitmentEntries(accountIDs: []).isEmpty)

        _ = try await store.beginAccountRemoval(accountID: "a", draftIDs: [])
        #expect(try await changes.next() == [])
        #expect(try await store.commitmentEntries(accountIDs: ["a", "b"]).map(\.record.accountID) == ["b"])
        await #expect(throws: CommitmentStoreError.unavailableAccount) {
            try await store.createCommitment(commitment(id: "new"))
        }
        await #expect(throws: CommitmentStoreError.unavailableAccount) {
            try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: "work", kind: .unresolved,
                expectedReminderRevision: 1, at: clock)
        }
        try await store.deleteAccount(id: "a")
        let remainingReminderAccounts = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT accountID FROM commitmentReminder")
        }
        #expect(remainingReminderAccounts == ["b"])
        #expect(try await store.commitmentEntries(accountIDs: ["b"]).count == 1)
    }

    @Test func reacceptingSuggestionsPreservesCorrectionsAndClosedStatus() async throws {
        let store = try await configuredStore()
        var original = commitment()
        original.acceptanceKey = "summary:message:task"
        var entry = try await store.createCommitment(original, reminders: [reminder(original)])
        entry.record.title = "Send the revised proposal"
        entry.record.ownerEmail = "corrected@example.com"
        entry.record.dueAt = clock + 86_400
        entry = try await store.saveCommitment(entry, expectedRevision: entry.record.revision, now: clock)
        entry = try await store.setCommitmentStatus(accountID: "a", id: original.id, status: .dismissed,
            expectedRevision: entry.record.revision, now: clock)
        var refreshed = original
        refreshed.id = "regenerated"
        refreshed.title = "Generated replacement"
        let duplicate = try await store.createCommitment(refreshed, reminders: [reminder(refreshed)])
        #expect(duplicate == entry)
        #expect(duplicate.record.ownerEmail == "corrected@example.com")
        #expect(duplicate.record.dueAt == clock + 86_400)
        #expect(duplicate.reminders.isEmpty)
        #expect(try await store.commitmentEntries(accountIDs: ["a"], includeClosed: false).isEmpty)
    }

    @Test func repliesSatisfyOnlyNoReplyAndDoNotResolveTheCommitment() async throws {
        let store = try await configuredStore()
        let record = commitment()
        let created = try await store.createCommitment(record, reminders: [reminder(record, .noReply), reminder(record, .unresolved)])
        let replyReminder = try #require(created.reminders.first { $0.kind == .noReply })
        #expect(try await !store.recordCommitmentReply(accountID: "a", commitmentID: record.id, messageID: "old",
            receivedAt: replyReminder.baselineDate, expectedReminderRevision: replyReminder.revision, now: clock))
        #expect(try await !store.recordCommitmentReply(accountID: "a", commitmentID: record.id,
            messageID: replyReminder.baselineMessageID, receivedAt: clock, expectedReminderRevision: replyReminder.revision, now: clock))
        #expect(try await store.recordCommitmentReply(accountID: "a", commitmentID: record.id, messageID: "reply",
            receivedAt: clock, expectedReminderRevision: replyReminder.revision, now: clock))
        let current = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(current.record.status == .open)
        #expect(current.reminders.first { $0.kind == .noReply }?.receivedReplyMessageID == "reply")
        let due = try await store.dueCommitmentReminders(accountIDs: ["a"], now: clock)
        #expect(due.flatMap(\.reminders).map(\.kind) == [.unresolved])
        // A reply in a different reminder does not invalidate this unresolved reminder's delivery.
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: 1, at: clock))
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: 1, at: clock))
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: clock).isEmpty)
    }

    @Test func staleEditorsAndInvalidReminderChangesCannotPartiallyOverwrite() async throws {
        let store = try await configuredStore()
        let original = commitment()
        var first = try await store.createCommitment(original, reminders: [reminder(original)])
        let stale = first
        first.record.title = "User correction"
        first = try await store.saveCommitment(first, expectedRevision: first.record.revision, now: clock)
        await #expect(throws: CommitmentStoreError.conflict) {
            try await store.saveCommitment(stale, expectedRevision: stale.record.revision, now: clock)
        }
        var invalid = first
        invalid.record.title = "Must roll back"
        invalid.reminders[0].accountID = "another-account"
        await #expect(throws: CommitmentStoreError.invalidRecord) {
            try await store.saveCommitment(invalid, expectedRevision: first.record.revision, now: clock)
        }
        #expect(try await store.commitmentEntries(accountIDs: ["a"]) == [first])
        invalid = first
        invalid.record.sourceMessageID = "another-message"
        await #expect(throws: CommitmentStoreError.invalidRecord) {
            try await store.saveCommitment(invalid, expectedRevision: first.record.revision, now: clock)
        }
    }

    @Test func reschedulingAndCancelReaddRejectStaleDeliveryAcknowledgements() async throws {
        let store = try await configuredStore()
        let record = commitment()
        var entry = try await store.createCommitment(record, reminders: [reminder(record)])
        let oldRevision = try #require(entry.reminders.first?.revision)
        entry = try await store.snoozeCommitmentReminder(accountID: "a", commitmentID: record.id, kind: .unresolved,
            until: clock + 600, expectedRevision: entry.record.revision, now: clock)
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: oldRevision, at: clock + 600))
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: entry.reminders[0].revision, at: clock))
        let snoozedRevision = entry.reminders[0].revision
        entry = try await store.cancelCommitmentReminder(accountID: "a", commitmentID: record.id, kind: .unresolved,
            expectedRevision: entry.record.revision, now: clock)
        entry.reminders = [reminder(record)]
        entry = try await store.saveCommitment(entry, expectedRevision: entry.record.revision, now: clock)
        #expect(entry.reminders[0].revision > snoozedRevision)
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: snoozedRevision, at: clock + 600))
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: entry.reminders[0].revision, at: clock))
    }

    @Test func editingTextPreservesReminderEvidenceAndReopeningDoesNotRearm() async throws {
        let store = try await configuredStore()
        let record = commitment()
        var entry = try await store.createCommitment(record, reminders: [reminder(record, .noReply), reminder(record, .unresolved)])
        let notificationID = "tern.followup.original-revision"
        let unresolvedNotificationID = "tern.followup.unresolved-revision"
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id, kind: .unresolved,
            expectedReminderRevision: 1, notificationID: unresolvedNotificationID, at: clock))
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id, kind: .noReply,
            expectedReminderRevision: entry.reminders[0].revision, notificationID: notificationID, at: clock))
        entry = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(entry.reminders.first?.notificationID == notificationID)
        #expect(try await store.recordCommitmentReply(accountID: "a", commitmentID: record.id, messageID: "reply",
            receivedAt: clock, expectedReminderRevision: entry.reminders[0].revision, now: clock))
        entry = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        entry.record.title = "Still need the actual approval"
        // An editor does not get to erase reply evidence by reconstructing its reminder value.
        entry.reminders = [reminder(record, .noReply), reminder(record, .unresolved)]
        entry = try await store.saveCommitment(entry, expectedRevision: entry.record.revision, now: clock)
        #expect(entry.reminders.first?.receivedReplyMessageID == "reply")
        #expect(entry.reminders.first?.notificationID == notificationID)
        #expect(entry.reminders.first?.deliveredAt == clock)
        entry.record.ownerEmail = " ALEX@EXAMPLE.COM "
        entry = try await store.saveCommitment(entry, expectedRevision: entry.record.revision, now: clock)
        #expect(entry.reminders.first?.receivedReplyMessageID == "reply")
        #expect(entry.reminders.first?.notificationID == notificationID)

        // A different participant changes the reply condition, but not the work's resolution reminder.
        entry.record.ownerEmail = "bob@example.com"
        entry = try await store.saveCommitment(entry, expectedRevision: entry.record.revision, now: clock)
        let corrected = try #require(entry.reminders.first { $0.kind == .noReply })
        #expect(corrected.receivedReplyMessageID == nil)
        #expect(corrected.receivedReplyAt == nil)
        #expect(corrected.deliveredAt == nil)
        #expect(corrected.notificationID == nil)
        #expect(corrected.baselineMessageID == record.sourceMessageID)
        #expect(corrected.baselineDate == record.sourceMessageDate)
        #expect(entry.reminders.first { $0.kind == .unresolved }?.notificationID == unresolvedNotificationID)
        #expect(entry.reminders.first { $0.kind == .unresolved }?.deliveredAt == clock)
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id, kind: .noReply,
            expectedReminderRevision: corrected.revision, notificationID: "tern.followup.corrected-revision", at: clock))
        entry = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(try await store.recordCommitmentReply(accountID: "a", commitmentID: record.id, messageID: "bob-reply",
            receivedAt: clock + 1, expectedReminderRevision: entry.reminders[0].revision, now: clock + 1))
        entry = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        entry = try await store.snoozeCommitmentReminder(accountID: "a", commitmentID: record.id, kind: .noReply,
            until: clock + 600, expectedRevision: entry.record.revision, now: clock)
        #expect(entry.reminders.first { $0.kind == .noReply }?.receivedReplyMessageID == "bob-reply")
        #expect(entry.reminders.first { $0.kind == .noReply }?.notificationID == nil)
        entry = try await store.setCommitmentStatus(accountID: "a", id: record.id, status: .completed,
            expectedRevision: entry.record.revision, now: clock)
        #expect(entry.reminders.isEmpty)
        entry = try await store.setCommitmentStatus(accountID: "a", id: record.id, status: .open,
            expectedRevision: entry.record.revision, now: clock)
        #expect(entry.record.title == "Still need the actual approval")
        #expect(entry.reminders.isEmpty)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: clock + 86_400).isEmpty)
    }
}

private func configuredStore() async throws -> AccountStore {
    let store = try AccountStore.inMemory()
    try await seedAccount(store, "a")
    return store
}

private func seedAccount(_ store: AccountStore, _ id: String) async throws {
    try await store.save(AccountRecord(id: id, email: "\(id)@example.com", displayName: nil, grantedScopes: [], addedAt: clock))
}

private func commitment(account: String = "a", id: String = "work") -> CommitmentRecord {
    CommitmentRecord(accountID: account, id: id, threadID: "thread", sourceMessageID: "source",
        sourceMessageDate: clock - 3_600, sourceSubject: "Proposal", title: "Approve proposal",
        ownerName: "Alex", ownerEmail: "alex@example.com", direction: .waitingFor, createdAt: clock - 3_600)
}

private func reminder(_ record: CommitmentRecord, _ kind: CommitmentReminderKind = .unresolved) -> CommitmentReminderRecord {
    CommitmentReminderRecord(accountID: record.accountID, commitmentID: record.id, kind: kind, remindAt: clock,
        baselineMessageID: record.sourceMessageID, baselineDate: record.sourceMessageDate, baselineHistoryID: 100)
}
