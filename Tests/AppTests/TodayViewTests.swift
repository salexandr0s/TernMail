import AppKit
import GmailAPI
import MailStore
import MessageContent
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct TodayViewTests {
    @Test(.timeLimit(.minutes(1))) func nativeDashboardSnoozesRestoresAndCompletesTrackedWork() async throws {
        let fixture = try await TodayNativeFixture()
        defer { fixture.stop() }
        let controller = NSHostingController(rootView: TodayView(model: fixture.today, dashboard: fixture.dashboard, isActive: true)
            .followUpEditor(model: fixture.followUps))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.close(); window.contentViewController = nil }
        try await until { fixture.today.historyReady && element("today-snooze-owed", in: controller.view) != nil }
        try await settle(window)
        window.appearance = NSAppearance(named: .aqua)
        try await settle(window)
        try capture(controller.view, name: "today-dashboard-wide")
        #expect(fixture.today.projection(now: fixture.now).sections.map(\.kind) == [.attention, .upcoming, .waiting, .changes])
        #expect((fixture.today.projection(now: fixture.now).rows.first?.reasons.count ?? 0) >= 2)

        try #require(press(try #require(element("today-source-owed", in: controller.view))))
        #expect(fixture.openedSource?.sourceMessageID == "source-owed")
        try #require(press(try #require(element("today-draft-owed", in: controller.view))))
        try await until { fixture.drafted?.id == "owed" && fixture.followUps.busyIDs.isEmpty }
        #expect(fixture.followUps.entries.first { $0.record.id == "owed" }?.record.status == .open)
        try await until {
            element("today-snooze-owed", in: controller.view).map { attribute("accessibilityEnabled", of: $0) as? Bool == true } ?? false
        }

        try #require(press(try #require(element("today-snooze-owed", in: controller.view))))
        try await until { window.attachedSheet?.contentView.map { element("today-snooze-save", in: $0) != nil } ?? false }
        let sheet = try #require(window.attachedSheet)
        try await settle(sheet)
        let sheetContent = try #require(sheet.contentView)
        try capture(sheetContent, name: "today-snooze")
        let saveSnooze = try #require(element("today-snooze-save", in: sheetContent))
        try #require(press(saveSnooze))
        try await until {
            window.attachedSheet == nil && fixture.followUps.busyIDs.isEmpty
                && fixture.followUps.entries.first { $0.record.id == "owed" }?.record.deferredUntil != nil
        }
        let deferred = try #require(fixture.followUps.entries.first { $0.record.id == "owed" })
        #expect(deferred.reminders.isEmpty, "Snooze must work without a reminder.")
        #expect(deferred.record.dueAt == fixture.deadline)
        try await scrollToBottom(controller.view, window: window)
        let picker = try #require(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 })
        picker.selectedSegment = 1
        picker.sendAction(picker.action, to: picker.target)
        try await until { element("today-bring-back-owed", in: controller.view) != nil }
        try await scrollToBottom(controller.view, window: window)
        try #require(press(try #require(element("today-bring-back-owed", in: controller.view))))
        try await until { fixture.followUps.entries.first { $0.record.id == "owed" }?.record.deferredUntil == nil && fixture.followUps.busyIDs.isEmpty }
        let briefingPicker = try #require(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 })
        briefingPicker.selectedSegment = 0
        briefingPicker.sendAction(briefingPicker.action, to: briefingPicker.target)
        try await scrollToTop(controller.view, window: window)
        try await until {
            guard let complete = element("today-status-owed", in: controller.view) else { return false }
            return attribute("accessibilityEnabled", of: complete) as? Bool == true
        }
        try #require(press(try #require(element("today-status-owed", in: controller.view))))
        try await until { fixture.followUps.entries.first { $0.record.id == "owed" }?.record.status == .completed }

        window.orderOut(nil)
        try await until { fixture.today.activeVisitID == nil }
        fixture.failHistory = true
        window.setContentSize(NSSize(width: 560, height: 720))
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        try await until { fixture.today.historyError != nil }
        try await scrollToTop(controller.view, window: window)
        try capture(controller.view, name: "today-dashboard-narrow-history-unavailable")
        #expect(fixture.today.projection(now: fixture.now).rowCount > 0, "Current work remains usable without visit history.")
    }

    private func scrollToTop(_ view: NSView, window: NSWindow) async throws {
        if let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).first {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await settle(window)
    }

    private func scrollToBottom(_ view: NSView, window: NSWindow) async throws {
        if let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await settle(window)
    }

    private func settle(_ window: NSWindow) async throws {
        window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func accessibilityObjects(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let children = attribute("accessibilityChildren", of: object) as? [NSObject] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children).compactMap({ $0 as? NSObject })
                + ((object as? NSView)?.subviews ?? []) { visit(child) }
        }
        visit(root); return result
    }
    private func attribute(_ name: String, of object: NSObject) -> Any? {
        let getter = name == "accessibilityEnabled" ? "isAccessibilityEnabled" : name
        if object.responds(to: NSSelectorFromString(getter)), let value = object.value(forKey: name) { return value }
        let attributes: [String: NSAccessibility.Attribute] = ["accessibilityChildren": .children, "accessibilityIdentifier": .identifier,
            "accessibilityRole": .role, "accessibilityEnabled": .enabled]
        guard let key = attributes[name], object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return object.accessibilityAttributeValue(key)
    }
    private func element(_ id: String, in root: NSView) -> NSObject? {
        let matches = accessibilityObjects(root).filter { attribute("accessibilityIdentifier", of: $0) as? String == id }
        return matches.first { attribute("accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue } ?? matches.first
    }
    private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        for candidate in accessibilityObjects(object) {
            if candidate.responds(to: selector), let implementation = candidate.method(for: selector) {
                // AppKit's public BOOL accessibilityPerformPress selector.
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(implementation, to: Press.self)(candidate, selector) { return true }
            }
            if candidate.responds(to: NSSelectorFromString("accessibilityActionNames")), candidate.accessibilityActionNames().contains(.press),
               candidate.responds(to: NSSelectorFromString("accessibilityPerformAction:")) {
                candidate.accessibilityPerformAction(.press); return true
            }
        }
        return false
    }
    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
    }
}

@MainActor private final class TodayNativeFixture {
    let store: AccountStore
    let now = Date.now
    let account = AccountRecord(id: "today-native", email: "alex@example.invalid", displayName: "Work",
        grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast, enabledFeatures: [AccountFeature.tasks.rawValue])
    let defaults: UserDefaults
    let suite = "TodayNative-\(UUID().uuidString)"
    let service = TodayNativeTasksService()
    var failHistory = false
    var openedSource: CommitmentRecord?
    var drafted: CommitmentRecord?
    var deadline: Date { FollowUpSchedule.canonicalDeadline(now.addingTimeInterval(-86400)) }
    lazy var followUps = FollowUpsModel(store: { self.store }, visibleAccountIDs: { [self.account.id] }, canReadAccount: { _ in false },
        loadThread: { _, _ in throw FollowUpModelError.unavailable }, prepareDraft: { self.drafted = $0; return "synthetic-draft" },
        openMail: { self.openedSource = $0 }, scheduler: SilentFollowUpNotificationScheduler(), now: { self.now })
    lazy var today = makeToday()
    lazy var tasks = GoogleTasksModel(defaults: defaults, loadAccounts: { [self.account] }, service: { _ in self.service }, enable: { _ in })
    lazy var dashboard = TodayDashboardModel(tasks: tasks,
        context: { TodayDashboardContext(profileID: nil, runtime: "native-fixture", accounts: [.init(id: self.account.id, runtime: "account", title: "Work")]) },
        loadUnread: { _ in TodayUnreadSnapshot(messages: [TodayUnreadMessage(accountID: self.account.id, threadID: "mail", messageID: "unread",
            sender: "Jordan", subject: "Notes for tomorrow’s review", snippet: "I’ve added the latest estimates and a short agenda.", date: self.now, accountTitle: "Work")],
            totalCount: 1, scannedConversationLimitReached: false, messageLimitReached: false) },
        loadCalendar: { _, _ in TodayCalendarSnapshot(events: [CalendarDisplayEvent(event: GoogleCalendarEvent(id: "review", summary: "Project review",
            start: .init(date: self.now.addingTimeInterval(3600)), end: .init(date: self.now.addingTimeInterval(7200))),
            accountID: self.account.id, calendarID: "work")], calendarCount: 1, unavailableCount: 0, omittedCount: 0, isStale: false) })

    init() async throws {
        store = try AccountStore.inMemory()
        defaults = try #require(UserDefaults(suiteName: suite))
        try await store.save(account)
        for (id, title, direction, due) in [
            ("owed", "Send the revised proposal to Anna", CommitmentDirection.owedByMe, Optional(deadline)),
            ("upcoming", "Confirm the workshop outline", .waitingFor, Optional(FollowUpSchedule.canonicalDeadline(now.addingTimeInterval(2 * 86400)))),
            ("waiting", "Get feedback on the launch copy", .waitingFor, nil),
            ("closed", "Approve the venue booking", .waitingFor, nil)
        ] {
            _ = try await store.createCommitment(CommitmentRecord(accountID: account.id, id: id, threadID: "thread-\(id)", sourceMessageID: "source-\(id)",
                sourceMessageDate: now.addingTimeInterval(-3600), sourceSubject: "Project planning", title: title, ownerName: "Anna", direction: direction, dueAt: due))
        }
        let initial = try await store.commitmentEntries(accountIDs: [account.id])
        _ = try await store.acknowledgeTodayVisit(scope: .all, accountIDs: [account.id], presentedEntries: initial, initialEntries: initial, now: now.addingTimeInterval(-60))
        let closed = try #require(initial.first { $0.record.id == "closed" })
        _ = try await store.setCommitmentStatus(accountID: account.id, id: closed.record.id, status: .completed, expectedRevision: closed.record.revision)
        await followUps.refresh(checkReminders: false)
    }

    private func makeToday() -> TodayModel {
        TodayModel(followUps: followUps, context: { TodayVisitContext(scope: .all, accountIDs: [self.account.id]) },
            canPresent: { true }, now: { self.now }, calendar: { .current },
            readHistory: { context in
                if self.failHistory { throw FollowUpModelError.unavailable }
                return try await self.store.todayVisitBaseline(scope: context.scope, accountIDs: context.accountIDs)
            }, saveHistory: { context, presented, initial, date in
                try await self.store.acknowledgeTodayVisit(scope: context.scope, accountIDs: context.accountIDs,
                    presentedEntries: presented, initialEntries: initial, now: date)
            })
    }

    func stop() { today.endVisit(); dashboard.stop(); followUps.stop(); tasks.stop(); defaults.removePersistentDomain(forName: suite) }
}

private actor TodayNativeTasksService: TasksService {
    var values = [GoogleTask(id: "brief", title: "Prepare review notes", notes: "Add the latest milestones.")]
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage { .init(items: [.init(id: "work", title: "Work tasks")]) }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage { .init(items: values) }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask { throw GmailError.notFound }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask {
        guard let index = values.firstIndex(where: { $0.id == taskID }) else { throw GmailError.notFound }
        if let completed = update.isCompleted { values[index].status = completed ? "completed" : "needsAction" }
        return values[index]
    }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws { values.removeAll { $0.id == taskID } }
}
