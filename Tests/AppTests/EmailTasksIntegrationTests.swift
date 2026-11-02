import AppKit
import MailStore
import MessageContent
import Observation
import SwiftUI
import Testing
import TernAI
import WebKit
@testable import Tern

@Suite @MainActor struct EmailTasksIntegrationTests {
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

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }

    private func element(_ id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func attribute(_ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
            }
            if attribute("accessibilityIdentifier") as? String == id { return object }
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
