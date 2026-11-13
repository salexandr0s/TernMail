import Foundation
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct TodayModelTests {
    @Test func firstPresentationSeedsSnoozedWorkThenOnlyPresentedChangesAreSeen() async throws {
        let fixture = try await TodayFixture()
        var active = try await fixture.create("active")
        var snoozed = try await fixture.create("snoozed", deferredUntil: fixture.time + 3_600)
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        await today.beginVisit()
        #expect(today.historyReady)
        #expect(try await fixture.history().initializedAccountIDs.isEmpty)
        #expect(today.projection(now: fixture.time).rows.count == 1)
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        let initial = try await fixture.history()
        #expect(initial.snapshots.count == 2)
        #expect(initial.snapshots[snoozed.id] == TodayCommitmentSnapshot(entry: snoozed))
        today.endVisit()

        active.record.title = "Changed visible work"
        active = try await fixture.store.saveCommitment(active, expectedRevision: active.record.revision)
        snoozed.record.title = "Changed hidden work"
        snoozed = try await fixture.store.saveCommitment(snoozed, expectedRevision: snoozed.record.revision)
        await fixture.followUps.refresh(checkReminders: false)
        await today.beginVisit()
        let rows = today.projection(now: fixture.time).rows
        #expect(rows.first?.reasons.contains { $0.code == .detailsChanged } == true)
        await today.acknowledgePresented(rows, visitID: try #require(today.activeVisitID))
        #expect(today.projection(now: fixture.time).rows.first?.reasons.contains { $0.code == .detailsChanged } == true)
        #expect(try await fixture.history().snapshots[snoozed.id] == initial.snapshots[snoozed.id])
        today.endVisit()
        await today.beginVisit()
        #expect(today.projection(now: fixture.time).rows.first?.reasons.contains { $0.code == .detailsChanged } == false)
        today.filter = .snoozed
        #expect(today.projection(now: fixture.time).rows.first?.reasons.contains { $0.code == .detailsChanged } == true)
        #expect(fixture.providerReads == 0)
    }

    @Test func emptyFirstPresentationSeedsExistingSnoozedWork() async throws {
        let fixture = try await TodayFixture()
        let hidden = try await fixture.create("hidden", deferredUntil: fixture.time + 3_600)
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        await today.beginVisit()
        #expect(today.projection(now: fixture.time).rowCount == 0)
        await today.acknowledgePresented([], visitID: try #require(today.activeVisitID))
        #expect(try await fixture.history().snapshots[hidden.id] == TodayCommitmentSnapshot(entry: hidden))
    }

    @Test func searchAndStaleRowsCannotConsumeUnseenChanges() async throws {
        let fixture = try await TodayFixture()
        var entry = try await fixture.create("tracked")
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        await today.beginVisit()
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        today.endVisit()
        entry.record.title = "Correction"
        entry = try await fixture.store.saveCommitment(entry, expectedRevision: entry.record.revision)
        await fixture.followUps.refresh(checkReminders: false)
        fixture.followUps.searchText = "Waiting for search excludes everything"
        await today.beginVisit()
        let captured = today.projection(now: fixture.time).rows
        #expect(captured.count == 1)
        today.searchText = "Today search excludes it"
        await today.acknowledgePresented(captured, visitID: try #require(today.activeVisitID))
        #expect(try await fixture.history().snapshots[entry.id]?.title == "tracked")
        today.searchText = ""
        entry.record.title = "Another correction"
        entry = try await fixture.store.saveCommitment(entry, expectedRevision: entry.record.revision)
        await fixture.followUps.refresh(checkReminders: false)
        await today.acknowledgePresented(captured, visitID: try #require(today.activeVisitID))
        #expect(try await fixture.history().snapshots[entry.id]?.title == "tracked")
    }

    @Test func failedHistoryKeepsCurrentWorkUsableAndDoesNotSeed() async throws {
        let fixture = try await TodayFixture()
        _ = try await fixture.create("tracked")
        fixture.failHistory = true
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        await today.beginVisit()
        #expect(!today.historyReady)
        #expect(today.historyError != nil)
        #expect(today.projection(now: fixture.time).rowCount == 1)
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        #expect(try await fixture.history().snapshots.isEmpty)
        fixture.failHistory = false
        await today.refresh()
        #expect(today.historyReady)
        #expect(today.historyError == nil)
        fixture.failSave = true
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        #expect(today.historyError != nil)
        #expect(try await fixture.history().snapshots.isEmpty)
        fixture.failSave = false
        await today.refresh()
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        #expect(today.historyError == nil)
        #expect(try await fixture.history().snapshots.count == 1)
    }

    @Test func oldPresentationAfterAnEditAndRevertCannotOverwriteANewerSeenSnapshot() async throws {
        let fixture = try await TodayFixture()
        var entry = try await fixture.create("original")
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        await today.beginVisit()
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        today.endVisit()
        await today.beginVisit()
        let olderRows = today.projection(now: fixture.time).rows
        entry.record.title = "New meaning"
        entry = try await fixture.store.saveCommitment(entry, expectedRevision: entry.record.revision)
        await fixture.followUps.refresh(checkReminders: false)
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        entry.record.title = "original"
        entry = try await fixture.store.saveCommitment(entry, expectedRevision: entry.record.revision)
        await fixture.followUps.refresh(checkReminders: false)
        await today.acknowledgePresented(olderRows, visitID: try #require(today.activeVisitID))
        #expect(try await fixture.history().snapshots[entry.id]?.title == "New meaning")
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        #expect(try await fixture.history().snapshots[entry.id]?.title == "original")
    }

    @Test func scopeSwitchAndCancelledLoadCannotPublishAnOldBaseline() async throws {
        let fixture = try await TodayFixture()
        _ = try await fixture.create("a-work")
        _ = try await fixture.create("b-work", accountID: "b")
        fixture.holdRead = true
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        let loading = Task { await today.beginVisit() }
        try await fixture.waitUntil { fixture.readContinuation != nil }
        today.endVisit()
        fixture.context = TodayVisitContext(scope: .all, accountIDs: ["b"])
        fixture.holdRead = false
        fixture.readContinuation?.resume(); fixture.readContinuation = nil
        await loading.value
        #expect(!today.historyReady)
        #expect(today.activeVisitID == nil)
        await today.beginVisit()
        #expect(today.projection(now: fixture.time).rows.map(\.entry.record.accountID) == ["b"])
        await today.acknowledgePresented(today.projection(now: fixture.time).rows, visitID: try #require(today.activeVisitID))
        #expect(try await fixture.store.todayVisitBaseline(scope: .all, accountIDs: ["a"]).initializedAccountIDs.isEmpty)
        #expect(try await fixture.store.todayVisitBaseline(scope: .all, accountIDs: ["b"]).initializedAccountIDs == ["b"])
    }

    @Test func endingVisitCancelsPendingAcknowledgementAndBackgroundCannotSeed() async throws {
        let fixture = try await TodayFixture()
        _ = try await fixture.create("tracked")
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        await today.beginVisit()
        fixture.holdSave = true
        let rows = today.projection(now: fixture.time).rows, id = try #require(today.activeVisitID)
        let saving = Task { await today.acknowledgePresented(rows, visitID: id) }
        try await fixture.waitUntil { fixture.saveContinuation != nil }
        today.endVisit()
        fixture.saveContinuation?.resume(); fixture.saveContinuation = nil
        await saving.value
        #expect(try await fixture.history().snapshots.isEmpty)
        fixture.canPresent = false
        await today.beginVisit()
        #expect(today.activeVisitID == nil)
        await today.acknowledgePresented(rows, visitID: id)
        #expect(try await fixture.history().snapshots.isEmpty)
    }

    @Test func visibleRowsSaveOneAtATimeAndAListQueuedDuringASaveIsNotLost() async throws {
        let fixture = try await TodayFixture()
        _ = try await fixture.create("first")
        _ = try await fixture.create("second")
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        await today.beginVisit()
        let rows = today.projection(now: fixture.time).rows, id = try #require(today.activeVisitID)
        #expect(rows.map(\.entry.record.id) == ["first", "second"])
        let first = try #require(rows.first)
        fixture.holdSave = true
        today.acknowledgeVisible([first], visitID: id)
        try await fixture.waitUntil { fixture.saveContinuation != nil }
        today.acknowledgeVisible([first], visitID: id)
        today.acknowledgeVisible(rows, visitID: id)
        fixture.holdSave = false
        fixture.saveContinuation?.resume(); fixture.saveContinuation = nil
        try await fixture.waitUntil { fixture.savedIDs.count == 2 }
        #expect(fixture.savedIDs == [["first"], ["second"]])
    }

    @Test func preparedListFollowsEntriesSearchAndFilterWithoutBeingAsked() async throws {
        let fixture = try await TodayFixture()
        _ = try await fixture.create("waiting")
        _ = try await fixture.create("snoozed", deferredUntil: fixture.time + 3_600)
        _ = try await fixture.store.createCommitment(CommitmentRecord(accountID: "a", id: "owed", threadID: "thread",
            sourceMessageID: "source", sourceMessageDate: fixture.time - 60, sourceSubject: "Subject", title: "owed",
            direction: .owedByMe, createdAt: fixture.time))
        let today = fixture.model()
        defer { today.endVisit(); fixture.followUps.stop() }
        #expect(today.presentation.rows.isEmpty)
        // Nothing tells Today that the follow-ups loaded. The page would show a stale list if it missed them.
        await fixture.followUps.refresh(checkReminders: false)
        try await fixture.waitUntil { today.presentation.rows.count == 2 }
        #expect(today.presentation.rows == today.projection(now: fixture.time).rows)
        #expect(today.presentation.owed.map(\.entry.record.id) == ["owed"])
        #expect(today.presentation.sections.map(\.kind) == [.waiting])
        #expect(today.presentation.sections.first?.rows.map(\.entry.record.id) == ["waiting"])
        #expect(today.presentation.followUpCount == 1)
        today.searchText = "owed"
        #expect(today.presentation.rows.map(\.entry.record.id) == ["owed"])
        #expect(today.presentation.sections.isEmpty)
        today.searchText = ""
        today.filter = .snoozed
        #expect(today.presentation.owed.isEmpty)
        #expect(today.presentation.sections.map(\.kind) == [.snoozed])
        #expect(today.presentation.rows.map(\.isSnoozed) == [true])
    }
}

@Suite @MainActor struct TodayProjectionTests {
    @Test func sectionsDeduplicateAndKeepEveryReason() {
        let clock = date("2026-11-03T12:00:00Z")
        var overdue = entry("overdue", direction: .owedByMe, dueAt: date("2026-11-02T00:00:00Z"))
        overdue.reminders = [reminder(overdue, remindAt: clock - 1)]
        let upcoming = entry("upcoming", dueAt: date("2026-11-05T00:00:00Z"))
        let waiting = entry("waiting")
        var closed = entry("closed")
        let baseline = TodayVisitBaseline(scope: .all, accountIDs: ["a"], initializedAccountIDs: ["a"],
            snapshots: [closed.id: TodayCommitmentSnapshot(entry: closed)])
        closed.record.status = .completed
        let result = TodayProjection.make(entries: [waiting, closed, upcoming, overdue], accountIDs: ["a"], baseline: baseline,
            now: clock, calendar: calendar("Europe/Vienna"))
        #expect(result.sections.map(\.kind) == [.attention, .upcoming, .waiting, .changes])
        #expect(result.rowCount == 4)
        let reasons = Set(result.rows.first?.reasons.map(\.code) ?? [])
        #expect(reasons.isSuperset(of: [.overdue, .reminderDue, .owedByMe]))
        #expect(result.rows.last?.reasons.contains { $0.code == .completed } == true)
    }

    @Test func calendarDayDeadlinesIncludeSeventhDayAcrossDSTAndTimeZones() {
        // Europe/Vienna's next week crosses the fall daylight-saving boundary.
        let clock = date("2026-10-24T22:30:00Z")
        let today = entry("today", dueAt: date("2026-10-25T00:00:00Z"))
        let seventh = entry("seventh", dueAt: date("2026-11-01T00:00:00Z"))
        let eighth = entry("eighth", dueAt: date("2026-11-02T00:00:00Z"))
        let result = TodayProjection.make(entries: [eighth, seventh, today], accountIDs: ["a"], baseline: nil,
            now: clock, calendar: calendar("Europe/Vienna"))
        #expect(result.sections.first?.rows.first?.id == today.id)
        #expect(result.sections.first?.rows.first?.reasons.contains { $0.code == .dueToday } == true)
        #expect(result.sections.first { $0.kind == .upcoming }?.rows.map(\.id) == [seventh.id])
        #expect(result.sections.first { $0.kind == .waiting }?.rows.map(\.id) == [eighth.id])
        let west = TodayProjection.make(entries: [today], accountIDs: ["a"], baseline: nil,
            now: clock, calendar: calendar("America/Los_Angeles"))
        #expect(west.rows.first?.reasons.contains { $0.code == .dueSoon } == true)
        #expect(west.rows.first?.reasons.contains { $0.code == .dueToday } == false)
    }

    @Test func notificationNoiseDoesNotBecomeAChangeAndReplyRemainsOpen() {
        let clock = date("2026-11-03T12:00:00Z")
        var original = entry("tracked")
        original.reminders = [reminder(original, remindAt: clock + 3_600)]
        let baseline = TodayVisitBaseline(scope: .all, accountIDs: ["a"], initializedAccountIDs: ["a"],
            snapshots: [original.id: TodayCommitmentSnapshot(entry: original)])
        var current = original
        current.record.updatedAt = clock; current.record.revision = 10
        current.reminders[0].revision = 11; current.reminders[0].deliveredAt = clock
        current.reminders[0].notificationID = "notification"
        #expect(TodayCommitmentSnapshot(entry: current) == TodayCommitmentSnapshot(entry: original))
        var result = TodayProjection.make(entries: [current], accountIDs: ["a"], baseline: baseline, now: clock)
        #expect(result.sections.map(\.kind) == [.waiting])
        #expect(result.rows.first?.reasons.contains { $0.code == .reminderChanged } == false)
        current.reminders[0].receivedReplyMessageID = "reply"; current.reminders[0].receivedReplyAt = clock
        result = TodayProjection.make(entries: [current], accountIDs: ["a"], baseline: baseline, now: clock)
        #expect(result.rows.first?.entry.record.status == .open)
        #expect(result.rows.first?.reasons.first { $0.code == .replyReceived }?.title == "Reply received since your last visit")
        #expect(result.rows.first?.reasons.contains { $0.code == .replyUnknown } == false)
    }

    @Test func deferralExpiresWithoutChangingStoredMeaning() {
        let clock = date("2026-11-03T12:00:00Z")
        var deferred = entry("deferred", direction: .owedByMe)
        deferred.record.deferredUntil = clock + 60
        let before = TodayCommitmentSnapshot(entry: deferred)
        #expect(TodayProjection.make(entries: [deferred], accountIDs: ["a"], baseline: nil, now: clock).rows.isEmpty)
        #expect(TodayProjection.make(entries: [deferred], accountIDs: ["a"], baseline: nil, filter: .snoozed, now: clock).rowCount == 1)
        #expect(TodayProjection.make(entries: [deferred], accountIDs: ["a"], baseline: nil, now: clock + 60).rowCount == 1)
        #expect(TodayCommitmentSnapshot(entry: deferred) == before)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: zone)!; return result
    }
    private func entry(_ id: String, direction: CommitmentDirection = .waitingFor, dueAt: Date? = nil) -> CommitmentEntry {
        CommitmentEntry(record: CommitmentRecord(accountID: "a", id: id, threadID: "thread-\(id)", sourceMessageID: "source",
            sourceMessageDate: date("2026-11-01T10:00:00Z"), sourceSubject: "Subject", title: id,
            ownerName: "Anna", direction: direction, dueAt: dueAt))
    }
    private func reminder(_ entry: CommitmentEntry, remindAt: Date) -> CommitmentReminderRecord {
        CommitmentReminderRecord(accountID: entry.record.accountID, commitmentID: entry.record.id, kind: .noReply,
            remindAt: remindAt, baselineMessageID: entry.record.sourceMessageID, baselineDate: entry.record.sourceMessageDate)
    }
}

@MainActor private final class TodayFixture {
    let store: AccountStore
    let time = Date(timeIntervalSince1970: 1_900_000_000)
    var context = TodayVisitContext(scope: .all, accountIDs: ["a"])
    var canPresent = true
    var failHistory = false
    var failSave = false
    var holdRead = false
    var holdSave = false
    var providerReads = 0
    var savedIDs: [[String]] = []
    var readContinuation: CheckedContinuation<Void, Never>?
    var saveContinuation: CheckedContinuation<Void, Never>?
    lazy var followUps = FollowUpsModel(store: { self.store }, visibleAccountIDs: { self.context.accountIDs },
        canReadAccount: { _ in false }, loadThread: { _, _ in
            self.providerReads += 1; throw FollowUpModelError.unavailable
        }, prepareDraft: { _ in throw FollowUpModelError.unavailable }, scheduler: SilentFollowUpNotificationScheduler(), now: { self.time })

    init() async throws {
        store = try AccountStore.inMemory()
        for id in ["a", "b"] {
            try await store.save(AccountRecord(id: id, email: "\(id)@example.com", displayName: id, grantedScopes: [], addedAt: time))
        }
    }

    func create(_ title: String, accountID: String = "a", deferredUntil: Date? = nil) async throws -> CommitmentEntry {
        try await store.createCommitment(CommitmentRecord(accountID: accountID, id: title, threadID: "thread", sourceMessageID: "source",
            sourceMessageDate: time - 60, sourceSubject: "Subject", title: title, direction: .waitingFor,
            deferredUntil: deferredUntil, createdAt: time))
    }

    func history() async throws -> TodayVisitBaseline { try await store.todayVisitBaseline(scope: .all, accountIDs: ["a"]) }

    func model() -> TodayModel {
        TodayModel(followUps: followUps, context: { self.context }, canPresent: { self.canPresent }, now: { self.time },
            readHistory: { context in
                if self.holdRead { await withCheckedContinuation { self.readContinuation = $0 } }
                try Task.checkCancellation()
                if self.failHistory { throw FollowUpModelError.unavailable }
                return try await self.store.todayVisitBaseline(scope: context.scope, accountIDs: context.accountIDs)
            }, saveHistory: { context, presented, initial, date in
                if self.holdSave { await withCheckedContinuation { self.saveContinuation = $0 } }
                try Task.checkCancellation()
                if self.failSave { throw FollowUpModelError.unavailable }
                self.savedIDs.append(presented.map(\.record.id))
                return try await self.store.acknowledgeTodayVisit(scope: context.scope, accountIDs: context.accountIDs,
                    presentedEntries: presented, initialEntries: initial, now: date)
            })
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw FollowUpModelError.unavailable
    }
}
