import Foundation
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct FollowUpsModelTests {
    @Test func replyClearsOnlyNoReplyAndAcceptedCorrectionsDoNotRearmIt() async throws {
        let fixture = try await FollowUpsFixture()
        let entry = try await fixture.create(kinds: [.noReply, .unresolved])
        fixture.snapshot.messages.append(fixture.message("reply", date: fixture.time - 5))
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        var saved = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(saved.record.status == .open)
        #expect(saved.reminders.first { $0.kind == .noReply }?.receivedReplyMessageID == "reply")
        #expect(saved.reminders.first { $0.kind == .unresolved }?.receivedReplyMessageID == nil)
        #expect(await fixture.scheduler.deliveries.count == 1)

        // A title-only edit of the satisfied no-reply reminder must preserve
        // the received-reply evidence instead of quietly starting a new wait.
        saved.reminders.removeAll { $0.kind == .unresolved }
        saved = try await fixture.store.saveCommitment(saved, expectedRevision: saved.record.revision, now: fixture.time)
        model.edit(saved)
        let request = try #require(model.pendingEditor)
        var values = request.values
        values.title = "Corrected description"
        #expect(await model.saveEditor(request, values: values))
        let edited = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(edited.record.id == entry.record.id)
        #expect(edited.record.title == values.title)
        #expect(edited.reminders.first?.receivedReplyMessageID == "reply")
        #expect(edited.reminders.first?.baselineMessageID == "source")
    }

    @Test func oldOutgoingDraftAndUnrelatedMessagesAreNotReplies() async throws {
        let fixture = try await FollowUpsFixture()
        let entry = try await fixture.create(kinds: [.noReply])
        let reminder = try #require(entry.reminders.first)
        var otherThread = fixture.message("other-thread", date: fixture.time - 10)
        otherThread.threadID = "another-thread"
        var otherAccount = fixture.message("other-account", date: fixture.time - 9)
        otherAccount.accountID = "b"
        let own = fixture.message("own-alias", date: fixture.time - 8, sender: "Alias <alias@example.com>")
        let unrelated = fixture.message("stranger", date: fixture.time - 7, sender: "stranger@example.com")
        let draft = fixture.message("draft", date: fixture.time - 6)
        fixture.snapshot.messages += [fixture.message("old", date: fixture.time - 100), otherThread,
                                      otherAccount, own, unrelated, draft]
        fixture.snapshot.labels["draft"] = [SystemLabel.draft]
        #expect(FollowUpsModel.reply(in: fixture.snapshot, to: entry.record, reminder: reminder) == nil)
        fixture.snapshot.messages.append(fixture.message("reply", date: fixture.time - 5))
        #expect(FollowUpsModel.reply(in: fixture.snapshot, to: entry.record, reminder: reminder)?.id == "reply")
        var ownOwner = entry.record
        ownOwner.ownerEmail = "alias@example.com"
        #expect(FollowUpsModel.reply(in: fixture.snapshot, to: ownOwner, reminder: reminder)?.id == "reply")
    }

    @Test func failedReplyCheckAndDeniedPermissionKeepDueWorkPending() async throws {
        let fixture = try await FollowUpsFixture()
        _ = try await fixture.create(kinds: [.noReply, .unresolved])
        fixture.failRead = true
        await fixture.scheduler.setPermission(.denied)
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        #expect(await fixture.scheduler.deliveries.isEmpty)
        var entry = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        let allPending = entry.reminders.allSatisfy { $0.isPending }
        #expect(allPending)
        #expect(model.replyCheckState(for: entry) == .unavailable)

        await fixture.scheduler.setPermission(.allowed)
        await model.refresh()
        entry = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(entry.reminders.first { $0.kind == .noReply }?.deliveredAt == nil)
        #expect(entry.reminders.first { $0.kind == .unresolved }?.deliveredAt != nil)
        #expect(await fixture.scheduler.deliveries.count == 1)
    }

    @Test func deliveredReminderDoesNotRepeatAndLaterReplyStillReconciles() async throws {
        let fixture = try await FollowUpsFixture()
        _ = try await fixture.create(kinds: [.noReply])
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        model.stop()
        await model.resume()
        #expect(await fixture.scheduler.deliveries.count == 1)
        fixture.snapshot.messages.append(fixture.message("later-reply", date: fixture.time - 1))
        await model.process(MailSyncNotification(accountID: "a", fromHistoryID: 100, toHistoryID: 102,
            messages: [MailNotificationMessage(record: fixture.message("later-reply", date: fixture.time - 1),
                                               labelIDs: [SystemLabel.inbox], addedHistoryID: 102)]))
        let saved = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(saved.record.status == .open)
        #expect(saved.reminders.first?.receivedReplyMessageID == "later-reply")
        #expect(await fixture.scheduler.deliveries.count == 1)
        let deliveredID = try #require(await fixture.scheduler.deliveries.first?.id)
        #expect(await fixture.scheduler.removals.contains(deliveredID))
    }

    @Test func completingAfterATitleEditRemovesTheDeliveredNotification() async throws {
        let fixture = try await FollowUpsFixture()
        _ = try await fixture.create(kinds: [.unresolved])
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        var entry = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        entry.record.title = "Updated description"
        entry = try await fixture.store.saveCommitment(entry, expectedRevision: entry.record.revision, now: fixture.time)
        await model.setStatus(entry, status: .completed)
        let deliveredID = try #require(await fixture.scheduler.deliveries.first?.id)
        #expect(await fixture.scheduler.removals.contains(deliveredID))
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first?.record.status == .completed)
    }

    @Test func explicitRescheduleUsesFreshBaselineAndDraftKeepsCommitmentOpen() async throws {
        let fixture = try await FollowUpsFixture()
        _ = try await fixture.create(kinds: [.noReply])
        fixture.snapshot.messages.append(fixture.message("reply", date: fixture.time - 2))
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        let answered = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        await model.snooze(answered, until: fixture.time + 86_400)
        let rearmed = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(rearmed.reminders.first?.baselineMessageID == "reply")
        #expect(rearmed.reminders.first?.receivedReplyMessageID == nil)
        #expect(await model.draftFollowUp(rearmed) == "draft-a-source")
        #expect(fixture.drafted == [rearmed.record])
        let afterDraft = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(afterDraft == rearmed)
    }

    @Test func editorCancellationRemovesTheActualDeliveredReminder() async throws {
        let fixture = try await FollowUpsFixture()
        _ = try await fixture.create(kinds: [.unresolved])
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        let entry = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        model.edit(entry)
        let request = try #require(model.pendingEditor)
        var values = request.values
        values.reminderKind = nil; values.remindAt = nil
        #expect(await model.saveEditor(request, values: values))
        let deliveredID = try #require(await fixture.scheduler.deliveries.first?.id)
        #expect(await fixture.scheduler.removals.contains(deliveredID))
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first?.reminders.isEmpty == true)
    }

    @Test func profileChangeDuringDeliveryRemovesAlertWithoutAcknowledgingIt() async throws {
        let fixture = try await FollowUpsFixture()
        _ = try await fixture.create(kinds: [.unresolved])
        await fixture.scheduler.onSchedule { @MainActor in fixture.visible = [] }
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        let saved = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(saved.reminders.first?.deliveredAt == nil)
        #expect(await fixture.scheduler.removals.count == 1)
        #expect(model.visibleEntries.isEmpty)
    }

    @Test func readdedAccountCanBeTrackedAfterOldRuntimeIsInvalidated() async throws {
        let fixture = try await FollowUpsFixture()
        _ = try await fixture.create(kinds: [])
        let model = fixture.model()
        defer { model.stop() }
        await model.refresh()
        await model.removeAccount("a")
        #expect(model.visibleEntries.isEmpty)
        model.restoreAccount("a")
        await model.refresh()
        #expect(model.visibleEntries.count == 1)
        model.beginTracking(source: FollowUpSource(record: fixture.source))
        #expect(model.pendingEditor?.source.accountID == "a")
    }
}

@MainActor private final class FollowUpsFixture {
    let time = Date(timeIntervalSince1970: 1_900_000_000)
    let store: AccountStore
    let scheduler = FollowUpsTestScheduler()
    var visible: Set<String> = ["a"]
    var failRead = false
    var snapshot: FollowUpThreadSnapshot
    var drafted: [CommitmentRecord] = []
    var source: MessageRecord { snapshot.messages[0] }

    init() async throws {
        store = try AccountStore.inMemory()
        let source = MessageRecord(accountID: "a", id: "source", threadID: "thread", historyID: 100,
            date: time - 60, snippet: "", sender: "me@example.com", recipients: "Anna <anna@example.com>",
            cc: nil, subject: "Proposal", sizeEstimate: 1, rfcMessageID: "<source@example.com>")
        snapshot = FollowUpThreadSnapshot(accountID: "a", threadID: "thread", messages: [source],
            labels: [source.id: [SystemLabel.sent]], ownAddresses: ["me@example.com", "alias@example.com"], checkedAt: time)
        try await store.save(AccountRecord(id: "a", email: "me@example.com", displayName: "Me", grantedScopes: [], addedAt: time))
    }

    func message(_ id: String, date: Date, sender: String = "Anna <anna@example.com>") -> MessageRecord {
        MessageRecord(accountID: "a", id: id, threadID: "thread", historyID: 101, date: date,
            snippet: "", sender: sender, recipients: "me@example.com", cc: nil, subject: "Re: Proposal", sizeEstimate: 1,
            rfcMessageID: "<\(id)@example.com>", inReplyTo: "<source@example.com>")
    }

    func create(kinds: [CommitmentReminderKind]) async throws -> CommitmentEntry {
        let record = CommitmentRecord(accountID: "a", id: "commitment", threadID: "thread", sourceMessageID: "source",
            sourceMessageDate: source.date, sourceSubject: source.subject, title: "Proposal approval",
            ownerName: "Anna", ownerEmail: "anna@example.com", direction: .waitingFor, createdAt: time - 30)
        return try await store.createCommitment(record, reminders: kinds.map {
            CommitmentReminderRecord(accountID: "a", commitmentID: record.id, kind: $0, remindAt: time - 10,
                baselineMessageID: source.id, baselineDate: source.date, baselineHistoryID: source.historyID)
        })
    }

    func model() -> FollowUpsModel {
        FollowUpsModel(store: { self.store }, visibleAccountIDs: { self.visible }, canReadAccount: { _ in !self.failRead },
            loadThread: { account, thread in
                guard !self.failRead, account == self.snapshot.accountID, thread == self.snapshot.threadID else {
                    throw FollowUpModelError.unavailable
                }
                return self.snapshot
            }, prepareDraft: { record in
                self.drafted.append(record)
                return "draft-\(record.accountID)-\(record.sourceMessageID)"
            }, scheduler: scheduler, now: { self.time })
    }
}

private actor FollowUpsTestScheduler: FollowUpNotificationScheduling {
    private var allowed: MailNotificationPermission = .allowed
    private(set) var deliveries: [FollowUpNotification] = []
    private(set) var removals: [String] = []
    private var callback: (@Sendable () async -> Void)?
    func setPermission(_ value: MailNotificationPermission) { allowed = value }
    func onSchedule(_ callback: @escaping @Sendable () async -> Void) { self.callback = callback }
    func permission() async -> MailNotificationPermission { allowed }
    func requestPermission() async throws -> Bool { allowed == .allowed }
    func schedule(_ notification: FollowUpNotification) async throws {
        deliveries.append(notification)
        await callback?()
    }
    func remove(id: String) async { removals.append(id) }
    func removeAccount(_ accountID: String) async {}
}
