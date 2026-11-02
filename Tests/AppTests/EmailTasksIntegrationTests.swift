import AppKit
import GmailAPI
import MailStore
import MessageContent
import Observation
import SwiftUI
import Testing
import TernAI
import WebKit
@testable import Tern

@Suite @MainActor struct EmailTasksIntegrationTests {
    @Test func rowEditAndDeleteRemainAccessibleWithoutOpeningAMenu() async throws {
        var edits = 0, deletions = 0
        let controller = NSHostingController(rootView: GoogleTaskRow(task: .init(id: "task", title: "Review proposal"),
            parentTitle: nil, isBusy: false, onComplete: {}, onEdit: { edits += 1 }, onDelete: { deletions += 1 }))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close() }
        try await waitFor { self.element("google-task-edit-button-task", in: controller.view) != nil }
        #expect(press(try #require(element("google-task-edit-button-task", role: "AXButton", in: controller.view))))
        #expect(press(try #require(element("google-task-delete-task", role: "AXButton", in: controller.view))))
        try await waitFor { edits == 1 && deletions == 1 }
    }

    @Test(.timeLimit(.minutes(1))) func selectedEmailTextReachesTheNativeTaskMenuAndExpiredSelectionsCannotRun() async throws {
        let fixture = SelectionFixture()
        let controller = NSHostingController(rootView: SelectionReader(fixture: fixture, blocker: await RemoteContentBlocker.ruleList()))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close() }
        try await waitFor { fixture.webView?.isLoading == false && fixture.webView?.url != nil }
        let view = try #require(fixture.webView)
        _ = try await view.evaluateJavaScript("""
            const range = document.createRange(); range.selectNodeContents(document.body);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            """, in: nil, contentWorld: .defaultClient)
        try await waitFor { view.taskSelectionText.contains("updated proposal") }
        let menu = NSMenu()
        view.addTaskSelectionItem(to: menu)
        #expect(menu.items.first?.identifier?.rawValue == "tern.add-selection-to-tasks")
        // Moving focus into a menu must not discard the text it was opened for.
        view.taskSelectionText = ""
        menu.performActionForItem(at: 0)
        #expect(fixture.additions == ["Please send the updated proposal."])

        view.taskSelectionText = "A stale selection"
        let stale = NSMenu()
        view.addTaskSelectionItem(to: stale)
        fixture.isActive = false
        try await waitFor { view.isHidden }
        stale.performActionForItem(at: 0)
        #expect(fixture.additions.count == 1)
        #expect(view.taskSelectionText.isEmpty)
        fixture.isActive = true
        try await waitFor { view.taskSelectionText.contains("updated proposal") }
        let restored = NSMenu()
        view.addTaskSelectionItem(to: restored)
        restored.performActionForItem(at: 0)
        #expect(fixture.additions == ["Please send the updated proposal.", "Please send the updated proposal."])
        view.clearTaskSelection()
        let empty = NSMenu()
        view.addTaskSelectionItem(to: empty)
        #expect(empty.items.isEmpty)
    }

    @Test func emailTaskRequestsKeepTheSourceAccountAndFullExcerptWithinGoogleLimits() async throws {
        let detail = try await detail()
        let message = try #require(detail.messages.first)
        #expect(EmailTaskRequest.selection(" \n ", message: message, accountEmail: nil) == nil)
        let selected = "Please follow up\n" + String(repeating: "Details ", count: 1_000)
        let request = try #require(EmailTaskRequest.selection(selected, message: message, accountEmail: "owner@example.invalid"))
        #expect(request.source?.accountID == "source-account")
        #expect(request.source?.messageID == "message")
        #expect(request.title.count <= 160)
        let draft = try request.draft(email: "owner@example.invalid")
        #expect((draft.notes?.count ?? 0) <= 8192)
        #expect(draft.notes?.contains("[Selection shortened]") == true)
        #expect(draft.notes?.contains("authuser=owner@example.invalid") == true)
        #expect(draft.notes?.contains("tern://conversation?") == true)
    }

    @Test func summaryTaskButtonSubmitsItsSuggestionFromTheRenderedSummary() async throws {
        let detail = try await detail()
        let suite = "tern.tasks.summary." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = GoogleTasksModel(defaults: defaults, loadAccounts: { [] }, service: { _ in nil }, enable: { _ in })
        let summary = try JSONDecoder().decode(AssistantSummary.self, from: Data("""
            {"summary":"A proposal is due.","source_ids":[],"decisions":[],
             "open_tasks":[{"description":"Send the proposal","owner":"Alex","due_date":"2026-11-05","source_ids":[]}]}
            """.utf8))
        let report = ThreadSummaryReport(summary: summary, sources: [], hasPartialCoverage: false)
        var additions: [TaskCreationRequest] = []
        let root = ThreadSummaryContent(report: report, detail: detail, onOpenSource: { _ in }, onRefresh: {}, onSettings: {},
            tasks: model, taskAccountEmail: "owner@example.invalid", onAddTask: { additions.append($0) })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close() }
        try await waitFor { self.element("summary-tasks-toggle", in: controller.view) != nil }
        try #require(press(try #require(element("summary-tasks-toggle", in: controller.view))))
        try await waitFor { self.element("summary-task-add-0", in: controller.view) != nil }
        try #require(press(try #require(element("summary-task-add-0", in: controller.view))))
        try await waitFor { additions.count == 1 }
        #expect(additions[0].title == "Send the proposal")
        #expect(additions[0].source?.accountID == "source-account")
        #expect(additions[0].dueDate == "2026-11-05")
        model.creationStates[additions[0].reference] = .added
        try await waitFor {
            self.element("summary-task-add-0", in: controller.view)?.value(forKey: "accessibilityEnabled") as? Bool == false
        }
    }

    @Test func refreshedAISuggestionsKeepOneIdentityAndDoNotTrustAForeignSourceAccount() async throws {
        let detail = try await detail()
        let trusted = AssistantSource(accountID: "source-account", threadID: "thread", messageID: "message", partID: nil, title: "Proposal")
        let foreign = AssistantSource(accountID: "another-account", threadID: "thread", messageID: "foreign", partID: nil, title: "Proposal")
        let task = try JSONDecoder().decode(AssistantSummary.OpenTask.self, from: Data("""
            {"description":"Send the proposal","owner":"Alex","due_date":"2026-11-05","source_ids":["\(foreign.id)","\(trusted.id)"]}
            """.utf8))
        let summary = try JSONDecoder().decode(AssistantSummary.self, from: Data("""
            {"summary":"A proposal is due.","source_ids":[],"decisions":[],"open_tasks":[]}
            """.utf8))
        let report = ThreadSummaryReport(summary: summary, sources: [foreign, trusted], hasPartialCoverage: false)
        let request = EmailTaskRequest.suggestion(task, report: report, detail: detail, accountEmail: nil)
        #expect(request.source?.accountID == "source-account")
        #expect(request.source?.messageID == "message")
        #expect(request.dueDate == "2026-11-05")
        #expect(request.notes == "Owner: Alex")
        var refreshed = request
        refreshed.dueDate = "2026-11-06"
        refreshed.source?.messageID = nil
        #expect(refreshed.reference == request.reference)
        refreshed.source?.accountID = "another-account"
        #expect(refreshed.reference != request.reference)
        let otherOwner = try JSONDecoder().decode(AssistantSummary.OpenTask.self, from: Data("""
            {"description":"Send the proposal","owner":"Sam","due_date":"2026-11-05","source_ids":["\(trusted.id)"]}
            """.utf8))
        #expect(EmailTaskRequest.suggestion(otherOwner, report: report, detail: detail, accountEmail: nil).reference != request.reference)
    }

    @Test func calendarTaskRequestsKeepTheDisplayedDaySourceAndSuggestionIdentity() async throws {
        let detail = try await detail()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        var event = GoogleCalendarEvent(summary: "Planning call")
        event.start = CalendarDateTime(dateTime: "2031-07-15T23:30:00Z")
        event.location = "Studio"
        var item = EmailCalendarItem(id: "interpreted:planning", messageID: "message", title: "Planning call",
            evidence: "Let's meet to plan the launch.", kind: .proposed, event: event)
        func request(_ item: EmailCalendarItem) -> TaskCreationRequest? {
            EmailTaskRequest.calendarSuggestion(item, detail: detail, calendar: calendar, accountEmail: "owner@example.invalid")
        }
        let task = try #require(request(item))
        #expect(task.title == "Planning call")
        #expect(task.dueDate == "2031-07-16")
        #expect(task.source?.accountID == "source-account")
        #expect(task.source?.messageID == "message")
        #expect(task.notes.contains(EmailCalendarPresentation(item: item, calendar: calendar).dateLine))
        #expect(task.notes.contains("Studio"))
        #expect(task.notes.contains(item.evidence))
        #expect(try task.draft(email: "owner@example.invalid").notes?.contains("authuser=owner@example.invalid") == true)
        #expect(try #require(request(item)).reference == task.reference)
        let other = EmailCalendarItem(id: "interpreted:another", messageID: "message", title: item.title,
            evidence: item.evidence, kind: .proposed, event: event)
        #expect(try #require(request(other)).reference != task.reference)

        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        item.event?.start = CalendarDateTime(date: "2031-07-15", timeZone: "Europe/Vienna")
        #expect(request(item)?.dueDate == "2031-07-15")
        #expect(request(item)?.reference == task.reference)
        item.isOutdated = true
        #expect(request(item) == nil)
        item.isOutdated = false
        item.kind = .cancelled
        item.existingEventID = "saved-event"
        #expect(request(item) == nil)
        let foreign = EmailCalendarItem(id: "foreign", messageID: "other-thread-message", title: item.title,
            evidence: item.evidence, kind: .proposed, event: event)
        #expect(request(foreign) == nil)
    }

    @Test(arguments: [560, 280])
    func calendarSuggestionPlusAddsATaskAndKeepsReviewAvailable(width: Int) async throws {
        let detail = try await detail()
        let suite = "tern.tasks.calendar." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tasks = GoogleTasksModel(defaults: defaults, loadAccounts: { [] }, service: { _ in nil }, enable: { _ in })
        let calendar = Calendar(identifier: .gregorian)
        let suggestions = EmailCalendarModel()
        let item = EmailCalendarItem(id: "interpreted:planning", messageID: "message", title: "Planning call",
            evidence: "Let's meet to plan the launch.", kind: .proposed,
            event: GoogleCalendarEvent(summary: "Planning call", start: CalendarDateTime(date: "2031-07-15")))
        suggestions.update(messages: [EmailCalendarMessage(id: "message", subject: item.title, date: .now, text: item.evidence)],
            addresses: [], now: Date(timeIntervalSince1970: 1_800_000_000))
        try #require(suggestions.restoreInterpretation([item], for: suggestions.revision))
        var additions: [TaskCreationRequest] = []
        var reviews: [String] = []
        let root = EmailCalendarSuggestionsView(model: suggestions, calendar: calendar,
            onReview: { reviews.append($0.id) }, onOpenExisting: { _ in }, onRespond: { _, _ in }, tasks: tasks,
            taskRequest: { EmailTaskRequest.calendarSuggestion($0, detail: detail, calendar: calendar, accountEmail: nil) },
            onAddTask: { additions.append($0) })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close() }
        let addID = "calendar-task-add-" + item.id
        let reviewID = "calendar-review-" + item.id
        try await waitFor { self.element(addID, in: controller.view) != nil && self.element(reviewID, in: controller.view) != nil }
        try #require(press(try #require(element(addID, in: controller.view))))
        try await waitFor { additions.count == 1 }
        #expect(additions[0].title == item.title)
        #expect(additions[0].dueDate == "2031-07-15")
        #expect(reviews.isEmpty)
        tasks.creationStates[additions[0].reference] = .added
        try await waitFor { self.element(addID, in: controller.view)?.value(forKey: "accessibilityEnabled") as? Bool == false }
        try #require(press(try #require(element(reviewID, in: controller.view))))
        try await waitFor { reviews == [item.id] }
        #expect(additions.count == 1)
    }

    private func detail() async throws -> ThreadDetail {
        let cache = try MailCache.inMemory()
        let record = MessageRecord(accountID: "source-account", id: "message", threadID: "thread", historyID: 1,
            date: .distantPast, snippet: "Please review.", sender: "sender@example.invalid",
            recipients: "owner@example.invalid", cc: nil, subject: "Proposal", sizeEstimate: 100)
        try await cache.write {
            _ = try $0.upsertMessages([.init(record: record, labelIDs: [SystemLabel.inbox])])
            try $0.rebuildThreads(["thread"], accountID: "source-account")
        }
        var iterator = cache.thread(accountID: "source-account", threadID: "thread").makeAsyncIterator()
        return try #require(try await iterator.next() ?? nil)
    }

    private func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func element(_ id: String, role: String? = nil, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func attribute(_ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
            }
            if attribute("accessibilityIdentifier") as? String == id,
               role == nil || attribute("accessibilityRole") as? String == role { return object }
            let children = attribute("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let result = visit(child) { return result }
            }
            return nil
        }
        return visit(root)
    }

    private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
        // Public AppKit accessibility selector: -(BOOL)accessibilityPerformPress.
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Press.self)(object, selector)
    }

    @Observable final class SelectionFixture {
        var height: CGFloat = 0
        var isActive = true
        var webView: ContentSizedWebView?
        var additions: [String] = []
    }

    private struct SelectionReader: View {
        let fixture: SelectionFixture
        let blocker: WKContentRuleList?

        var body: some View {
            MessageWebView(html: MessageDocument.render(plainText: "Please send the updated proposal.").html,
                blocker: blocker, height: Binding(get: { fixture.height }, set: { fixture.height = $0 }),
                isActive: fixture.isActive, onAddSelectionToTasks: { fixture.additions.append($0) },
                onCreate: { fixture.webView = $0 as? ContentSizedWebView })
        }
    }
}
