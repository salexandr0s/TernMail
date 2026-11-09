import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct TodayDashboardModelTests {
    @Test func unreadUsesEffectiveInboxLabelsAndAccountQualifiedIdentity() {
        let scope = Self.scope("a", "b")
        let unread: Set<String> = [SystemLabel.inbox, SystemLabel.unread]
        let entries = [Self.entry("a", "same", labels: unread, seconds: 20),
            Self.entry("b", "same", labels: unread, seconds: 30),
            Self.entry("a", "same", labels: unread, seconds: 20),
            Self.entry("outside", "hidden", labels: unread, seconds: 90),
            Self.entry("a", "read", labels: [SystemLabel.inbox], seconds: 80),
            Self.entry("a", "archive", labels: [SystemLabel.unread], seconds: 70),
            Self.entry("a", "trash", labels: unread.union([SystemLabel.trash]), seconds: 60),
            Self.entry("a", "spam", labels: unread.union([SystemLabel.spam]), seconds: 50),
            Self.entry("a", "draft", labels: unread.union([SystemLabel.draft]), seconds: 40)]
        let result = TodayUnreadSnapshot.make(page: MailListPage(threads: [], entries: entries), context: scope, totalCount: 42)
        #expect(result.messages.map(\.accountID) == ["b", "a"])
        #expect(Set(result.messages.map(\.id)).count == 2)
        #expect(result.messages.first?.link == MailLink(accountID: "b", threadID: "thread", messageID: "same"))
        #expect(result.totalCount == 42)
        #expect(result.coverage.contains("cached"))
        let limited = TodayUnreadSnapshot.make(page: MailListPage(threads: [], entries: entries), context: scope, totalCount: nil, limit: 1)
        #expect(limited.messages.count == 1)
        #expect(limited.messageLimitReached)
    }

    @Test func profileAndRuntimeChangeHideCachedMailAndRejectLateReadsAndOldLinks() async throws {
        let fixture = try TodayDashboardFixture()
        defer { fixture.clean() }
        let scope = TodayDashboardTestScope(Self.scope("a"))
        let gate = TodayDashboardGate()
        var reads = 0
        var opened: [MailLink] = []
        let model = TodayDashboardModel(tasks: fixture.tasks(), context: { scope.value }, loadUnread: { captured in
            reads += 1
            if reads == 2 { await gate.hold() }
            return Self.unread(captured)
        }, loadCalendar: { _ in Self.emptyCalendar }, openMail: { opened.append($0) })
        await model.refreshUnread()
        let old = try #require(model.unreadMessages.first)
        #expect(opened.isEmpty)
        let reading = Task { await model.refreshUnread() }
        await gate.waitUntilHeld()
        scope.value = TodayDashboardContext(profileID: "other", runtime: "replacement", accounts: Self.scope("a").accounts)
        #expect(model.unreadMessages.isEmpty)
        model.openUnread(old)
        #expect(opened.isEmpty)
        await gate.release()
        await reading.value
        #expect(model.unreadMessages.isEmpty)
        await model.refreshUnread()
        model.openUnread(try #require(model.unreadMessages.first))
        #expect(opened == [old.link])
        model.stop()
        #expect(model.unreadMessages.isEmpty)
    }

    @Test func calendarLoadsCoalesceAndStopDiscardsACompletedOldRequest() async throws {
        let fixture = try TodayDashboardFixture()
        defer { fixture.clean() }
        let scope = Self.scope("a")
        let gate = TodayDashboardGate()
        var reads = 0
        let model = TodayDashboardModel(tasks: fixture.tasks(), context: { scope }, loadUnread: { Self.unread($0) }, loadCalendar: { _ in
            reads += 1
            await gate.hold()
            return Self.emptyCalendar
        })
        let first = Task { await model.refreshCalendar() }
        await gate.waitUntilHeld()
        var entered = false
        let second = Task { entered = true; await model.refreshCalendar() }
        while !entered { await Task.yield() }
        #expect(reads == 1)
        model.stop()
        await gate.release()
        await first.value
        await second.value
        #expect(model.monthEvents.isEmpty)
        #expect(!model.calendarLoading)
        #expect(model.calendarCoverage.contains("not loaded"))
    }

    @Test func agendaUsesSelectedDayExclusiveEndsAndIncludesNextMonth() async throws {
        let fixture = try TodayDashboardFixture()
        defer { fixture.clean() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        calendar.firstWeekday = 2
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 30)))
        let end = try #require(calendar.date(byAdding: .day, value: 7, to: day))
        let events = [Self.event("ends-at-start", start: day.addingTimeInterval(-3600), end: day),
            Self.event("today", start: day.addingTimeInterval(3600), end: day.addingTimeInterval(7200)),
            Self.event("next-month", start: end.addingTimeInterval(-7200), end: end.addingTimeInterval(-3600)),
            Self.event("after-window", start: end, end: end.addingTimeInterval(3600))]
        let scope = Self.scope("a")
        let model = TodayDashboardModel(tasks: fixture.tasks(), context: { scope }, calendar: { calendar },
            loadUnread: { Self.unread($0) }, loadCalendar: { _ in
                TodayCalendarSnapshot(events: events, calendarCount: 1, unavailableCount: 1, omittedCount: 0, isStale: true)
            })
        model.selectedDate = day
        #expect(model.calendarRequest.interval.end >= end)
        await model.refreshCalendar()
        #expect(model.dayEvents.map(\.event.id) == ["today"])
        #expect(model.upcomingEvents.map(\.event.id) == ["today", "next-month"])
        #expect(model.calendarIsStale)
        #expect(model.calendarCoverage.contains("unavailable"))
        #expect(model.calendarCoverage.contains("cached"))
    }

    @Test func taskRowsAndEditorKeepTheirListAndRejectProfileChanges() async throws {
        let fixture = try TodayDashboardFixture()
        defer { fixture.clean() }
        fixture.defaults.set("list", forKey: "googleTasks.selectedList.a")
        let account = AccountRecord(id: "a", email: "a@example.invalid", displayName: "A", grantedScopes: [], addedAt: .now)
        let tasks = fixture.tasks(accounts: [account])
        let scope = TodayDashboardTestScope(Self.scope("a"))
        let model = TodayDashboardModel(tasks: tasks, context: { scope.value },
            loadUnread: { Self.unread($0) }, loadCalendar: { _ in Self.emptyCalendar })
        await model.refresh()
        tasks.lists = [.init(id: "list", title: "First list"), .init(id: "other", title: "Other list")]
        tasks.tasks = [.init(id: "same-id", title: "Original task")]
        let row = try #require(model.taskRows.first)
        let editor = try #require(model.makeTaskEditor(row))
        #expect(editor.location == GoogleTaskLocation(accountID: "a", listID: "list"))
        scope.value = Self.scope("b")
        #expect(model.taskRows.isEmpty)
        #expect(model.makeTaskEditor(row) == nil)
        await model.completeTask(row)
        await model.deleteTask(row)
        #expect(tasks.tasks.first?.title == "Original task")
        #expect(editor.location.accountID == "a")
    }

    private static var emptyCalendar: TodayCalendarSnapshot {
        TodayCalendarSnapshot(events: [], calendarCount: 0, unavailableCount: 0, omittedCount: 0, isStale: false)
    }
    private static func scope(_ ids: String...) -> TodayDashboardContext {
        TodayDashboardContext(profileID: nil, runtime: "mail-runtime", accounts: ids.map {
            TodayDashboardAccount(id: $0, runtime: "runtime-\($0)", title: "Account \($0)")
        })
    }
    private static func unread(_ scope: TodayDashboardContext) -> TodayUnreadSnapshot {
        TodayUnreadSnapshot.make(page: MailListPage(threads: [], entries: scope.accounts.map {
            entry($0.id, "message", labels: [SystemLabel.inbox, SystemLabel.unread], seconds: 0)
        }), context: scope, totalCount: nil)
    }
    private static func entry(_ account: String, _ id: String, labels: Set<String>, seconds: Double) -> MessageListEntry {
        MessageListEntry(message: MessageRecord(accountID: account, id: id, threadID: "thread", historyID: 1,
            date: Date(timeIntervalSince1970: seconds), snippet: "Snippet", sender: "Sender", recipients: "Me", cc: nil,
            subject: "Subject", sizeEstimate: 100), labels: labels)
    }
    private static func event(_ id: String, start: Date, end: Date) -> CalendarDisplayEvent {
        CalendarDisplayEvent(event: GoogleCalendarEvent(id: id, summary: id,
            start: CalendarDateTime(date: start), end: CalendarDateTime(date: end)), accountID: "a", calendarID: "calendar")
    }
}

@MainActor private final class TodayDashboardTestScope {
    var value: TodayDashboardContext
    init(_ value: TodayDashboardContext) { self.value = value }
}

@MainActor private struct TodayDashboardFixture {
    let suite = "TodayDashboardModelTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
    func clean() { defaults.removePersistentDomain(forName: suite) }
    func tasks(accounts: [AccountRecord] = []) -> GoogleTasksModel {
        GoogleTasksModel(defaults: defaults, loadAccounts: { accounts }, service: { _ in nil }, enable: { _ in })
    }
}

private actor TodayDashboardGate {
    private var isHeld = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        await withCheckedContinuation { continuation in
            held = continuation; isHeld = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }
    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { held?.resume(); held = nil }
}
