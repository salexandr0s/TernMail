import Foundation
import GRDB
import Testing
@testable import MailStore

private let automaticClock = Date(timeIntervalSince1970: 1_900_000_000)
private let automaticDay: TimeInterval = 86_400

@Suite struct AutomaticFollowUpStoreTests {
    @Test func reconciliationDeduplicatesAndAdvancesOnlyTheOutgoingBaseline() async throws {
        let store = try await automaticStore()
        let original = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        let repeated = try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1, eligibleForAlerts: true, now: automaticClock + 1)
        #expect(repeated.entry == original)
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: original.record.id, kind: .noReply,
            expectedReminderRevision: original.reminders[0].revision, notificationID: "original-alert", at: automaticClock))
        let next = try await store.reconcileAutomaticFollowUp(automaticCandidate(message: "next", date: automaticClock), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock)
        let advanced = try #require(next.entry)
        #expect(next.removedNotificationIDs == ["original-alert"])
        #expect(advanced.record.id == original.record.id)
        #expect(advanced.record.sourceMessageID == "sent")
        #expect(advanced.record.sourceMessageDate == original.record.sourceMessageDate)
        #expect(advanced.reminders[0].baselineMessageID == "next")
        #expect(advanced.reminders[0].deliveredAt == nil)
        #expect(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1, eligibleForAlerts: true,
            now: automaticClock).entry == advanced)
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: original.record.id, kind: .noReply,
            expectedReminderRevision: original.reminders[0].revision, at: automaticClock + automaticDay))
        #expect(try await store.commitmentEntries(accountIDs: ["a"]).count == 1)
    }

    @Test func manualWorkWinsBeforeAndAfterAutomaticAdoption() async throws {
        let store = try await automaticStore()
        var manual = automaticManual(thread: "manual")
        manual.status = .dismissed
        let saved = try await store.createCommitment(manual)
        #expect(try await store.reconcileAutomaticFollowUp(automaticCandidate(thread: "manual"), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry == saved)
        #expect(try await store.automaticFollowUps(accountIDs: ["a"]).first?.managed == false)

        let automatic = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        let laterManual = try await store.createCommitment(automaticManual())
        let entries = try await store.commitmentEntries(accountIDs: ["a"])
        #expect(entries.first { $0.record.id == automatic.record.id }?.reminders.isEmpty == true)
        #expect(entries.contains(laterManual))
        #expect(try await store.reconcileAutomaticFollowUp(automaticCandidate(message: "next", date: automaticClock), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry?.reminders.isEmpty == true)
    }

    @Test func quietAdoptionSurvivesTitleEditsAndOnlyExplicitReschedulingReleasesIt() async throws {
        let store = try await automaticStore()
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 1,
            enabledSince: automaticClock, now: automaticClock)
        var entry = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        #expect(entry.reminders[0].remindAt <= automaticClock)
        #expect(entry.reminders[0].deliveredAt == nil)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: automaticClock).isEmpty)
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: entry.record.id, kind: .noReply,
            expectedReminderRevision: entry.reminders[0].revision, at: automaticClock))
        #expect(try await store.claimAutomaticFollowUpDraft(accountID: "a", commitmentID: entry.record.id,
            expectedReminderRevision: entry.reminders[0].revision, now: automaticClock) == nil)
        entry.record.title = "My corrected task"
        entry = try await store.saveCommitment(entry, expectedRevision: entry.record.revision, now: automaticClock)
        #expect(try await store.automaticFollowUps(accountIDs: ["a"]).first?.managed == false)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: automaticClock).isEmpty)
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 10,
            enabledSince: automaticClock, now: automaticClock)
        #expect(try await store.commitmentEntries(accountIDs: ["a"]).first == entry)
        entry = try await store.snoozeCommitmentReminder(accountID: "a", commitmentID: entry.record.id, kind: .noReply,
            until: automaticClock + 10, expectedRevision: entry.record.revision, now: automaticClock)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: automaticClock + 10).count == 1)
        #expect(try await store.claimAutomaticFollowUpDraft(accountID: "a", commitmentID: entry.record.id,
            expectedReminderRevision: entry.reminders[0].revision, now: automaticClock + 10) == nil)
    }

    @Test func settingsPreserveReplyHistoryRejectStaleDiscoveryAndQuietReenable() async throws {
        let store = try await automaticStore()
        let enabledSince = automaticClock - 10 * automaticDay + 0.123456
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 1,
            enabledSince: enabledSince, now: enabledSince)
        var entry = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: entry.record.id, kind: .noReply,
            expectedReminderRevision: entry.reminders[0].revision, notificationID: "alert", at: automaticClock))
        entry = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 1,
            enabledSince: enabledSince, now: automaticClock)
        #expect(try await store.commitmentEntries(accountIDs: ["a"]).first == entry)
        #expect(try await store.disableAutomaticFollowUps(accountIDs: ["a"], now: automaticClock) == ["alert"])
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: automaticClock).isEmpty)
        #expect(try await store.reconcileAutomaticFollowUp(automaticCandidate(thread: "unseen"), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry == nil)
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 1,
            enabledSince: automaticClock, now: automaticClock)
        #expect(try await store.automaticFollowUps(accountIDs: ["a"]).first?.eligibleForAlerts == false)
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 3,
            enabledSince: automaticClock, now: automaticClock)
        #expect(try await store.automaticFollowUps(accountIDs: ["a"]).first?.eligibleForAlerts == true)
        entry = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(entry.reminders[0].remindAt == automaticClock + automaticDay)
        #expect(try await store.recordCommitmentReply(accountID: "a", commitmentID: entry.record.id, messageID: "reply",
            receivedAt: automaticClock, expectedReminderRevision: entry.reminders[0].revision, now: automaticClock))
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: false, delayDays: 3,
            enabledSince: automaticClock, now: automaticClock)
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 4,
            enabledSince: automaticClock + 1, now: automaticClock + 1)
        let replied = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(replied.reminders[0].receivedReplyMessageID == "reply")
        #expect(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry == replied)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: automaticClock + 10 * automaticDay).isEmpty)
    }

    @Test func newlyActiveAccountsAdoptQuietlyWithoutResettingContinuouslyActiveAccounts() async throws {
        let store = try await automaticStore()
        let globalEpoch = automaticClock - 30 * automaticDay
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true, delayDays: 1,
            enabledSince: globalEpoch, now: automaticClock - 20 * automaticDay)
        let ongoing = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: ongoing.record.id, kind: .noReply,
            expectedReminderRevision: ongoing.reminders[0].revision, notificationID: "keep-ongoing", at: automaticClock))
        let delivered = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)

        try await seedAutomaticAccount(store, "b")
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a", "b"], activeAccountIDs: ["a", "b"],
            enabled: true, delayDays: 1, enabledSince: globalEpoch, now: automaticClock)
        let initial = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(account: "b"), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        #expect(try await store.automaticFollowUps(accountIDs: ["b"]).first?.eligibleForAlerts == false)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["b"], now: automaticClock).isEmpty)
        #expect(try await store.claimAutomaticFollowUpDraft(accountID: "b", commitmentID: initial.record.id,
            expectedReminderRevision: initial.reminders[0].revision, now: automaticClock) == nil)
        #expect(try await store.commitmentEntries(accountIDs: ["a"]).first == delivered)

        _ = try await store.reconcileAutomaticFollowUp(automaticCandidate(account: "b", message: "new-sent", date: automaticClock),
            delayDays: 1, eligibleForAlerts: true, now: automaticClock)
        #expect(try await store.automaticFollowUps(accountIDs: ["b"]).first?.eligibleForAlerts == true)
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a", "b"], activeAccountIDs: ["a"],
            enabled: true, delayDays: 1, enabledSince: globalEpoch, now: automaticClock + 2 * automaticDay)
        #expect(try await store.automaticFollowUps(accountIDs: ["b"]).first?.scheduleEnabled == false)
        #expect(try await store.reconcileAutomaticFollowUp(automaticCandidate(account: "b", thread: "inactive"), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock + 2 * automaticDay).entry == nil)

        let reactivatedAt = automaticClock + 4 * automaticDay
        _ = try await store.configureAutomaticFollowUps(accountIDs: ["a", "b"], activeAccountIDs: ["a", "b"],
            enabled: true, delayDays: 1, enabledSince: globalEpoch, now: reactivatedAt)
        #expect(try await store.automaticFollowUps(accountIDs: ["b"]).first?.eligibleForAlerts == false)
        let newlyDiscovered = try #require(try await store.reconcileAutomaticFollowUp(
            automaticCandidate(account: "b", thread: "discovered-late", date: automaticClock + 2 * automaticDay), delayDays: 1,
            eligibleForAlerts: true, now: reactivatedAt).entry)
        #expect(try await store.claimAutomaticFollowUpDraft(accountID: "b", commitmentID: newlyDiscovered.record.id,
            expectedReminderRevision: newlyDiscovered.reminders[0].revision, now: reactivatedAt) == nil)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["b"], now: reactivatedAt).isEmpty)
        #expect(try await store.commitmentEntries(accountIDs: ["a"]).first == delivered)
        let resumed = try #require(try await store.reconcileAutomaticFollowUp(
            automaticCandidate(account: "b", message: "sent-after-reactivation", date: reactivatedAt), delayDays: 1,
            eligibleForAlerts: true, now: reactivatedAt).entry)
        #expect(resumed.record.sourceMessageID == initial.record.sourceMessageID)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["b"], now: reactivatedAt + automaticDay).count == 1)
    }

    @Test func explicitActionsEndManagementAndStaleEditorsCannotDoSo() async throws {
        for action in ["edit", "complete", "dismiss", "snooze", "cancel", "defer"] {
            let store = try await automaticStore()
            var entry = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
                eligibleForAlerts: true, now: automaticClock).entry)
            await #expect(throws: CommitmentStoreError.conflict) {
                try await store.saveCommitment(entry, expectedRevision: 0, now: automaticClock)
            }
            #expect(try await store.automaticFollowUps(accountIDs: ["a"]).first?.managed == true)
            switch action {
            case "edit":
                entry.record.ownerEmail = "corrected@example.com"
                entry = try await store.saveCommitment(entry, expectedRevision: entry.record.revision, now: automaticClock)
            case "complete", "dismiss":
                entry = try await store.setCommitmentStatus(accountID: "a", id: entry.record.id,
                    status: action == "complete" ? .completed : .dismissed, expectedRevision: entry.record.revision, now: automaticClock)
            case "snooze":
                entry = try await store.snoozeCommitmentReminder(accountID: "a", commitmentID: entry.record.id, kind: .noReply,
                    until: automaticClock + 500, expectedRevision: entry.record.revision, now: automaticClock)
            case "cancel":
                entry = try await store.cancelCommitmentReminder(accountID: "a", commitmentID: entry.record.id, kind: .noReply,
                    expectedRevision: entry.record.revision, now: automaticClock)
            default:
                entry = try await store.setCommitmentDeferral(accountID: "a", id: entry.record.id, until: automaticClock + 500,
                    expectedRevision: entry.record.revision, now: automaticClock)
            }
            #expect(try await store.automaticFollowUps(accountIDs: ["a"]).first?.managed == false)
            #expect(try await store.reconcileAutomaticFollowUp(automaticCandidate(message: "next", date: automaticClock), delayDays: 1,
                eligibleForAlerts: true, now: automaticClock).entry == entry)
        }
    }

    @Test func draftReservationsSurviveRelaunchAndCacheResetWithoutDuplicateClaims() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.sqlite")
        let store = try AccountStore.open(at: url)
        try await seedAutomaticAccount(store, "a")
        let entry = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        async let first = store.claimAutomaticFollowUpDraft(accountID: "a", commitmentID: entry.record.id,
            expectedReminderRevision: entry.reminders[0].revision, draftID: "first", now: automaticClock + 0.123456)
        async let second = store.claimAutomaticFollowUpDraft(accountID: "a", commitmentID: entry.record.id,
            expectedReminderRevision: entry.reminders[0].revision, draftID: "second", now: automaticClock + 0.123456)
        let claims = try await [first, second].compactMap { $0 }
        #expect(claims.count == 1)
        let claim = try #require(claims.first)
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: entry.record.id, kind: .noReply,
            expectedReminderRevision: entry.reminders[0].revision, at: automaticClock + 1))
        #expect(try await store.validateAutomaticFollowUpDraftClaim(claim, now: automaticClock + 1))
        let reopened = try AccountStore.open(at: url)
        #expect(try await reopened.validateAutomaticFollowUpDraftClaim(claim, now: automaticClock + 1))
        #expect(try await reopened.finishAutomaticFollowUpDraft(claim, state: .uncertain, now: automaticClock + 1))
        #expect(try await !reopened.finishAutomaticFollowUpDraft(claim, state: .prepared, now: automaticClock + 2))
        let cache = try MailCache.inMemory()
        try await cache.resetDisposableCache()
        let latest = try #require(try await reopened.commitmentEntries(accountIDs: ["a"]).first)
        #expect(try await reopened.claimAutomaticFollowUpDraft(accountID: "a", commitmentID: entry.record.id,
            expectedReminderRevision: latest.reminders[0].revision, now: automaticClock + 2) == nil)
        let next = try #require(try await reopened.reconcileAutomaticFollowUp(automaticCandidate(message: "next", date: automaticClock),
            delayDays: 1, eligibleForAlerts: true, now: automaticClock).entry)
        #expect(try await reopened.claimAutomaticFollowUpDraft(accountID: "a", commitmentID: entry.record.id,
            expectedReminderRevision: next.reminders[0].revision, now: automaticClock + automaticDay) != nil)
    }

    @Test func draftsRejectStaleConditionsAndAccountRemovalCascades() async throws {
        let store = try await automaticStore()
        try await seedAutomaticAccount(store, "b")
        for account in ["a", "b"] {
            let entry = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(account: account), delayDays: 1,
                eligibleForAlerts: true, now: automaticClock).entry)
            #expect(try await store.claimAutomaticFollowUpDraft(accountID: account, commitmentID: entry.record.id,
                expectedReminderRevision: 0, now: automaticClock) == nil)
            let claim = try #require(try await store.claimAutomaticFollowUpDraft(accountID: account, commitmentID: entry.record.id,
                expectedReminderRevision: entry.reminders[0].revision, now: automaticClock))
            #expect(try await store.recordCommitmentReply(accountID: account, commitmentID: entry.record.id, messageID: "reply",
                receivedAt: automaticClock, expectedReminderRevision: entry.reminders[0].revision, now: automaticClock))
            #expect(try await !store.validateAutomaticFollowUpDraftClaim(claim, now: automaticClock))
            #expect(try await store.finishAutomaticFollowUpDraft(claim, state: .blocked, now: automaticClock))
        }
        _ = try await store.beginAccountRemoval(accountID: "a", draftIDs: [])
        #expect(try await store.automaticFollowUps(accountIDs: ["a", "b"]).map(\.accountID) == ["b"])
        await #expect(throws: CommitmentStoreError.unavailableAccount) {
            try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1, eligibleForAlerts: true, now: automaticClock)
        }
        try await store.deleteAccount(id: "a")
        let receiptAccounts = try await store.writer.read { db in try String.fetchAll(db, sql: "SELECT accountID FROM automaticFollowUpDraft") }
        #expect(receiptAccounts == ["b"])
    }

    @Test func removalDeletesOnlyTheFollowUpsTernManagesWithTheirRecords() async throws {
        let store = try await automaticStore()
        let made = try #require(try await store.reconcileAutomaticFollowUp(automaticCandidate(), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock).entry)
        _ = try #require(try await store.claimAutomaticFollowUpDraft(accountID: "a", commitmentID: made.record.id,
            expectedReminderRevision: made.reminders[0].revision, now: automaticClock))
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: made.record.id, kind: .noReply,
            expectedReminderRevision: made.reminders[0].revision, notificationID: "alert", at: automaticClock))
        let manual = try await store.createCommitment(automaticManual(thread: "manual"))
        _ = try await store.reconcileAutomaticFollowUp(automaticCandidate(thread: "manual"), delayDays: 1,
            eligibleForAlerts: true, now: automaticClock)

        #expect(try await store.removeAutomaticFollowUp(accountID: "a", threadID: "thread") == ["alert"])
        #expect(try await store.removeAutomaticFollowUp(accountID: "a", threadID: "thread").isEmpty)
        #expect(try await store.removeAutomaticFollowUp(accountID: "a", threadID: "manual").isEmpty)
        #expect(try await store.commitmentEntries(accountIDs: ["a"]).map(\.record.id) == [manual.record.id])
        #expect(try await store.automaticFollowUps(accountIDs: ["a"]).map(\.threadID) == ["manual"])
        let leftovers = try await store.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM commitmentReminder WHERE commitmentID = ?)
                    + (SELECT COUNT(*) FROM automaticFollowUpDraft WHERE commitmentID = ?)
                """, arguments: [made.record.id, made.record.id])
        }
        #expect(leftovers == 0)
    }

    @Test func cachedCandidateScanReturnsOneRecentSentPerThreadAndStaysBounded() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for index in 0..<105 {
                try tx.upsertMessages([.init(record: automaticMessage(id: "sent-\(index)", thread: "thread-\(index)", date: automaticClock), labelIDs: [SystemLabel.sent])])
            }
            try tx.upsertMessages([
                .init(record: automaticMessage(id: "newest", thread: "thread-1", date: automaticClock + 1), labelIDs: [SystemLabel.sent]),
                .init(record: automaticMessage(id: "local-send:pending", thread: "local", date: automaticClock + 2), labelIDs: [SystemLabel.sent]),
                .init(record: automaticMessage(id: "trashed", thread: "trash", date: automaticClock + 2), labelIDs: [SystemLabel.sent, SystemLabel.trash]),
                .init(record: automaticMessage(id: "received", thread: "inbox", date: automaticClock + 2), labelIDs: [SystemLabel.inbox]),
                .init(record: automaticMessage(id: "old", thread: "old", date: automaticClock - automaticDay), labelIDs: [SystemLabel.sent])
            ])
        }
        let candidates = try await cache.read { try $0.automaticFollowUpCandidates(accountID: "a", since: automaticClock, limit: 500) }
        #expect(candidates.count == 100)
        #expect(candidates.first?.id == "newest")
        #expect(Set(candidates.map(\.threadID)).count == candidates.count)
        #expect(!candidates.contains { ["old", "trashed", "received", "local-send:pending"].contains($0.id) })
        #expect(try await cache.read { try $0.automaticFollowUpCandidates(accountID: "b", since: automaticClock) }.isEmpty)
    }
}

private func automaticStore() async throws -> AccountStore {
    let store = try AccountStore.inMemory()
    try await seedAutomaticAccount(store, "a")
    return store
}

private func seedAutomaticAccount(_ store: AccountStore, _ id: String) async throws {
    try await store.save(AccountRecord(id: id, email: "\(id)@example.com", displayName: nil, grantedScopes: [], addedAt: automaticClock))
}

private func automaticCandidate(account: String = "a", thread: String = "thread", message: String = "sent",
                                date: Date = automaticClock - 2 * automaticDay) -> AutomaticFollowUpCandidate {
    AutomaticFollowUpCandidate(accountID: account, threadID: thread, outgoingMessageID: message, outgoingDate: date,
        sourceSubject: "Proposal", title: "Follow up on proposal", ownerName: "Alex", ownerEmail: "alex@example.com", baselineHistoryID: 1)
}

private func automaticManual(thread: String = "thread") -> CommitmentRecord {
    CommitmentRecord(accountID: "a", threadID: thread, sourceMessageID: "manual-source", sourceMessageDate: automaticClock,
        sourceSubject: "Proposal", title: "My task", direction: .owedByMe, createdAt: automaticClock)
}

private func automaticMessage(id: String, thread: String, date: Date) -> MessageRecord {
    MessageRecord(accountID: "a", id: id, threadID: thread, historyID: 1, date: date, snippet: "",
        sender: "a@example.com", recipients: "alex@example.com", cc: nil, subject: "Proposal", sizeEstimate: 0)
}
