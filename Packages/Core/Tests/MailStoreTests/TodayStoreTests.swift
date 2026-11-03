import Foundation
import GRDB
import Testing
@testable import MailStore

private let todayClock = Date(timeIntervalSince1970: 1_900_000_000)

@Suite struct TodayStoreTests {
    @Test func migrationPreservesExistingFollowUpsWithNoDeferral() async throws {
        let writer = try DatabaseQueue()
        try Schema.configMigrator.migrate(writer, upTo: "commitment-notification-id-v1")
        try await writer.write { db in
            try AccountRecord(id: "a", email: "a@example.com", displayName: nil, grantedScopes: [], addedAt: todayClock).insert(db)
            try db.execute(sql: """
                INSERT INTO commitment(accountID,id,threadID,sourceMessageID,sourceMessageDate,sourceSubject,title,
                    direction,status,createdAt,updatedAt,revision) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: ["a", "work", "thread", "source", todayClock - 3_600, "Proposal", "Approve proposal",
                    "waitingFor", "open", todayClock - 3_600, todayClock - 3_600, 1])
            try todayReminder(todayCommitment()).insert(db)
        }
        let upgraded = try AccountStore(writer: writer)
        let entry = try #require(try await upgraded.commitmentEntries(accountIDs: ["a"]).first)
        #expect(entry.record.title == "Approve proposal")
        #expect(entry.record.deferredUntil == nil)
        #expect(entry.reminders.count == 1)
        #expect(try await upgraded.todayVisitBaseline(scope: .all, accountIDs: ["a"]).initializedAccountIDs.isEmpty)
    }

    @Test func firstVisitSeedsDeferredRecordsAndLaterVisitsAcknowledgeOnlyPresentedContent() async throws {
        let store = try await todayStore()
        var visible = try await store.createCommitment(todayCommitment(id: "visible"))
        var hidden = try await store.createCommitment(todayCommitment(id: "hidden", deferredUntil: todayClock + 3_600))
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"]).initializedAccountIDs.isEmpty)
        let seeded = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [visible], initialEntries: [visible, hidden], now: todayClock)
        #expect(seeded.initializedAccountIDs == ["a"])
        #expect(seeded.acknowledgedIDs == [visible.id, hidden.id])
        let original = try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"])
        #expect(original.snapshots[hidden.id]?.deferredUntil == todayClock + 3_600)

        visible.record.dueAt = todayClock + 86_400
        visible = try await store.saveCommitment(visible, expectedRevision: visible.record.revision, now: todayClock + 1)
        hidden.record.title = "Unseen correction"
        hidden = try await store.saveCommitment(hidden, expectedRevision: hidden.record.revision, now: todayClock + 1)
        _ = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [visible], initialEntries: [visible, hidden], now: todayClock + 2)
        let next = try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"])
        #expect(next.snapshots[visible.id] == TodayCommitmentSnapshot(entry: visible))
        #expect(next.snapshots[hidden.id] == original.snapshots[hidden.id])
        #expect(next.snapshots[hidden.id] != TodayCommitmentSnapshot(entry: hidden))
    }

    @Test func anOlderFirstVisitCannotSeedNewUnseenRecords() async throws {
        let store = try await todayStore()
        let first = try await store.createCommitment(todayCommitment(id: "first"))
        let second = try await store.createCommitment(todayCommitment(id: "second"))
        let stale = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [first], initialEntries: [first], now: todayClock)
        #expect(stale.initializedAccountIDs.isEmpty)
        #expect(stale.acknowledgedIDs.isEmpty)
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"]).snapshots.isEmpty)
        let fresh = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [first, second], initialEntries: [first, second], now: todayClock + 1)
        #expect(fresh.initializedAccountIDs == ["a"])
        #expect(fresh.acknowledgedIDs.count == 2)
    }

    @Test func stalePresentationsCannotConsumeChangesOrOverwriteNewerSeenStateAfterARevert() async throws {
        let store = try await todayStore()
        let original = try await store.createCommitment(todayCommitment())
        _ = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [original], initialEntries: [original], now: todayClock)
        var changed = original
        changed.record.title = "Changed description"
        changed = try await store.saveCommitment(changed, expectedRevision: changed.record.revision, now: todayClock + 1)
        let stale = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [original], initialEntries: [], now: todayClock + 2)
        #expect(stale.acknowledgedIDs.isEmpty)
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"]).snapshots[original.id] == TodayCommitmentSnapshot(entry: original))
        _ = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [changed], initialEntries: [], now: todayClock + 3)
        var reverted = changed
        reverted.record.title = original.record.title
        reverted = try await store.saveCommitment(reverted, expectedRevision: reverted.record.revision, now: todayClock + 4)
        #expect(TodayCommitmentSnapshot(entry: reverted) == TodayCommitmentSnapshot(entry: original))
        let oldAck = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [original], initialEntries: [], now: todayClock + 5)
        #expect(oldAck.acknowledgedIDs.isEmpty)
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"]).snapshots[changed.id] == TodayCommitmentSnapshot(entry: changed))
    }

    @Test func notificationOnlyRevisionChangesDoNotInvalidateThePresentedMeaning() async throws {
        let store = try await todayStore()
        let record = todayCommitment()
        let presented = try await store.createCommitment(record, reminders: [todayReminder(record)])
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: 1, notificationID: "submitted", at: todayClock))
        let current = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(presented.record.revision != current.record.revision)
        #expect(TodayCommitmentSnapshot(entry: presented) == TodayCommitmentSnapshot(entry: current))
        let ack = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"],
            presentedEntries: [presented], initialEntries: [presented], now: todayClock)
        #expect(ack.initializedAccountIDs == ["a"])
        #expect(ack.acknowledgedIDs == [presented.id])
    }

    @Test func profileBaselinesAreIndependentAndCascadeWithTheirProfileAndAccounts() async throws {
        let store = try await todayStore()
        try await store.save(AccountRecord(id: "b", email: "b@example.com", displayName: nil, grantedScopes: [], addedAt: todayClock))
        try await store.saveMailProfile(MailProfile(id: "work", name: "Work"))
        _ = try await store.updateMailPreferences(accountID: "a") { $0.profileID = "work" }
        let a = try await store.createCommitment(todayCommitment())
        let b = try await store.createCommitment(todayCommitment(account: "b"))
        _ = try await store.acknowledgeTodayVisit(scope: .profile("work"), accountIDs: ["a"],
            presentedEntries: [a], initialEntries: [a], now: todayClock)
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["a", "b"]).initializedAccountIDs.isEmpty)
        _ = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a", "b"],
            presentedEntries: [a, b], initialEntries: [a, b], now: todayClock)
        _ = try await store.updateMailPreferences(accountID: "b") { $0.profileID = "work" }
        #expect(try await store.todayVisitBaseline(scope: .profile("work"), accountIDs: ["a", "b"]).initializedAccountIDs == ["a"])
        let joined = try await store.acknowledgeTodayVisit(scope: .profile("work"), accountIDs: ["a", "b"],
            presentedEntries: [b], initialEntries: [a, b], now: todayClock + 1)
        #expect(joined.initializedAccountIDs == ["a", "b"])
        try await store.deleteMailProfile(id: "work")
        await #expect(throws: TodayVisitStoreError.unavailableScope) {
            try await store.todayVisitBaseline(scope: .profile("work"), accountIDs: ["a", "b"])
        }
        let profileRows = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM todaySeenCommitment WHERE scopeKey = 'profile:work'")
        }
        #expect(profileRows == 0)
        try await store.deleteAccount(id: "a")
        let remaining = try await store.todayVisitBaseline(scope: .all, accountIDs: ["a", "b"])
        #expect(remaining.accountIDs == ["b"])
        #expect(Set(remaining.snapshots.keys) == [b.id])
        _ = try await store.beginAccountRemoval(accountID: "b", draftIDs: [])
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["b"]).snapshots.isEmpty)
        await #expect(throws: TodayVisitStoreError.unavailableScope) {
            try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["b"], presentedEntries: [b], initialEntries: [], now: todayClock)
        }
    }

    @Test func visitHistorySurvivesReopenAndInvalidHistoryDoesNotBecomeAnEmptyBaseline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.sqlite")
        let store = try AccountStore.open(at: url)
        try await store.save(AccountRecord(id: "a", email: "a@example.com", displayName: nil, grantedScopes: [], addedAt: todayClock))
        let entry = try await store.createCommitment(todayCommitment())
        _ = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"], presentedEntries: [entry], initialEntries: [entry], now: todayClock)
        let cache = try MailCache.inMemory()
        try await cache.resetDisposableCache()
        let reopened = try AccountStore.open(at: url)
        #expect(try await reopened.todayVisitBaseline(scope: .all, accountIDs: ["a"]).snapshots[entry.id] == TodayCommitmentSnapshot(entry: entry))
        try await reopened.writer.write { db in try db.execute(sql: "UPDATE todaySeenCommitment SET snapshot = '{'") }
        await #expect(throws: DecodingError.self) {
            try await reopened.todayVisitBaseline(scope: .all, accountIDs: ["a"])
        }
    }

    @Test func deferralWorksWithoutRemindersAndCannotBeLostThroughAStaleEditor() async throws {
        let store = try await todayStore()
        let original = try await store.createCommitment(todayCommitment())
        var deferred = try await store.setCommitmentDeferral(accountID: "a", id: original.record.id,
            until: todayClock + 3_600, expectedRevision: original.record.revision, now: todayClock)
        #expect(deferred.record.deferredUntil == todayClock + 3_600)
        #expect(deferred.record.dueAt == original.record.dueAt)
        #expect(deferred.record.sourceMessageID == original.record.sourceMessageID)
        #expect(deferred.reminders.isEmpty)
        await #expect(throws: CommitmentStoreError.conflict) {
            try await store.setCommitmentDeferral(accountID: "a", id: original.record.id,
                until: nil, expectedRevision: original.record.revision, now: todayClock)
        }
        var droppedDeferral = deferred
        droppedDeferral.record.deferredUntil = nil
        await #expect(throws: CommitmentStoreError.invalidRecord) {
            try await store.saveCommitment(droppedDeferral, expectedRevision: deferred.record.revision, now: todayClock)
        }
        deferred = try await store.setCommitmentDeferral(accountID: "a", id: original.record.id,
            until: nil, expectedRevision: deferred.record.revision, now: todayClock + 1)
        #expect(deferred.record.deferredUntil == nil)
    }

    @Test func deferralSuppressesDeliveryButAllowsReplyReconciliationAndExpiry() async throws {
        let store = try await todayStore()
        let record = todayCommitment()
        _ = try await store.createCommitment(record, reminders: [todayReminder(record, .noReply), todayReminder(record, .unresolved)])
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: 1, notificationID: "old", at: todayClock))
        var current = try #require(try await store.commitmentEntries(accountIDs: ["a"]).first)
        current = try await store.setCommitmentDeferral(accountID: "a", id: record.id,
            until: todayClock + 3_600, expectedRevision: current.record.revision, now: todayClock)
        let unresolved = try #require(current.reminders.first { $0.kind == .unresolved })
        let noReply = try #require(current.reminders.first { $0.kind == .noReply })
        #expect(unresolved.deliveredAt == nil)
        #expect(unresolved.notificationID == nil)
        #expect(noReply.baselineDate == record.sourceMessageDate)
        #expect(try await store.dueCommitmentReminders(accountIDs: ["a"], now: todayClock).isEmpty)
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: unresolved.revision, at: todayClock + 1))
        #expect(try await store.recordCommitmentReply(accountID: "a", commitmentID: record.id, messageID: "reply",
            receivedAt: todayClock + 2, expectedReminderRevision: noReply.revision, now: todayClock + 2))
        let dueAtExpiry = try await store.dueCommitmentReminders(accountIDs: ["a"], now: todayClock + 3_600)
        #expect(dueAtExpiry.flatMap(\.reminders).map(\.kind) == [.unresolved])
        #expect(dueAtExpiry.first?.record.status == .open)
        #expect(try await !store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: 1, at: todayClock + 3_600))
        #expect(try await store.markCommitmentReminderDelivered(accountID: "a", commitmentID: record.id,
            kind: .unresolved, expectedReminderRevision: unresolved.revision, at: todayClock + 3_600))
    }

    @Test func anEmptyVisitInitializesAndCancelledAcknowledgementsDoNotWrite() async throws {
        let store = try await todayStore()
        let empty = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: [], presentedEntries: [], initialEntries: [], now: todayClock)
        #expect(empty.initializedAccountIDs.isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"], presentedEntries: [], initialEntries: [], now: todayClock)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"]).initializedAccountIDs.isEmpty)
        let initial = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: ["a"], presentedEntries: [], initialEntries: [], now: todayClock)
        #expect(initial.initializedAccountIDs == ["a"])
        let newWork = try await store.createCommitment(todayCommitment())
        #expect(try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"]).snapshots[newWork.id] == nil)
    }
}

private func todayStore() async throws -> AccountStore {
    let store = try AccountStore.inMemory()
    try await store.save(AccountRecord(id: "a", email: "a@example.com", displayName: nil, grantedScopes: [], addedAt: todayClock))
    return store
}

private func todayCommitment(account: String = "a", id: String = "work", deferredUntil: Date? = nil) -> CommitmentRecord {
    CommitmentRecord(accountID: account, id: id, threadID: "thread", sourceMessageID: "source", sourceMessageDate: todayClock - 3_600,
        sourceSubject: "Proposal", title: "Approve proposal", ownerName: "Alex", ownerEmail: "alex@example.com",
        direction: .waitingFor, dueAt: todayClock + 7_200, deferredUntil: deferredUntil, createdAt: todayClock - 3_600)
}

private func todayReminder(_ record: CommitmentRecord, _ kind: CommitmentReminderKind = .unresolved) -> CommitmentReminderRecord {
    CommitmentReminderRecord(accountID: record.accountID, commitmentID: record.id, kind: kind, remindAt: todayClock,
        baselineMessageID: record.sourceMessageID, baselineDate: record.sourceMessageDate)
}
