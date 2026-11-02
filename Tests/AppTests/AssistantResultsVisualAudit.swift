import AppKit
import Foundation
import GmailAPI
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Opt-in captures render production views using synthetic mail and local services.
@Suite @MainActor struct AssistantResultsVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func renderTaskAndEventResults() async throws {
        for (width, scheme) in [(320.0, ColorScheme.dark), (380.0, .light), (720.0, .light)] {
            let name = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
            try await capture(ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    AssistantMarkdownView(text: """
                    ## Your next steps
                    The proposal needs your review before Friday. The design review is on Thursday.
                    """)
                    taskCard(Self.task, state: .idle)
                    eventCard(Self.timedEvent)
                    AssistantMarkdownView(text: """
                    - [ ] Confirm the revised budget
                    - [x] Send the meeting notes
                    """)
                }.padding(Tokens.Space.s4)
            }, size: NSSize(width: width, height: 900), scheme: scheme, name: "mixed-\(name)")

            try await capture(ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    taskCard(Self.undatedTask, state: .idle)
                    taskCard(Self.savedTask, state: .added)
                    eventCard(Self.allDayEvent)
                    eventCard(Self.undatedEvent)
                }.padding(Tokens.Space.s4)
            }, size: NSSize(width: width, height: 980), scheme: scheme,
                name: "states-\(name)", captureBottom: true)
        }
        try await capture(taskCard(Self.task, state: .idle).padding(Tokens.Space.s4),
            size: NSSize(width: 380, height: 520), scheme: .light, name: "source-excerpt", expandExcerpt: true)

        let suite = "AssistantResultsVisualAudit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountRecord(id: "assistant-visual", email: "alex@studio.example", displayName: "Work",
            grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast,
            enabledFeatures: [AccountFeature.tasks.rawValue])
        let service = AssistantVisualTasksService()
        let model = GoogleTasksModel(defaults: defaults, loadAccounts: { [account] },
            service: { _ in service }, enable: { _ in })
        await model.refreshAccounts()
        for scheme in [ColorScheme.light, .dark] {
            try await capture(AssistantTaskReview(request: Self.task.request, model: model, isAuthorized: { true }),
                size: NSSize(width: Tokens.Sheet.smallWidth, height: 700), scheme: scheme,
                name: "task-review-\(scheme == .dark ? "dark" : "light")", waitFor: "alex@studio.example")
        }
    }

    private func taskCard(_ task: AssistantTaskResult, state: TaskCreationState) -> some View {
        AssistantTaskCard(task: task, state: state, isEnabled: true, onReview: {}, onOpenSource: { _ in })
    }

    private func eventCard(_ event: AssistantEventResult) -> some View {
        AssistantEventCard(event: event, isEnabled: true, isReviewing: false, error: nil,
            onReview: {}, onOpenSource: { _ in })
    }

    private static let source = AssistantSource(accountID: "assistant-visual", threadID: "launch", messageID: "m1",
        partID: nil, title: "Project launch: revised proposal, final delivery dates and the design review with the wider team")
    private static var task: AssistantTaskResult {
        .init(source: source, title: "Review the revised proposal and confirm the delivery schedule with the project team",
            owner: "Alex Morgan", notes: "Check the revised estimate before approving the next phase.", dueDate: "2026-11-06",
            evidence: "Could you review the revised proposal and confirm the delivery schedule by Friday, 6 November?")
    }
    private static var undatedTask: AssistantTaskResult {
        .init(source: source, title: "Ask the team for the final estimate", owner: nil,
            notes: "The email does not include a deadline.", dueDate: nil, evidence: "Please ask the team for the final estimate.")
    }
    private static var savedTask: AssistantTaskResult {
        .init(source: source, title: "Send the meeting notes", owner: "You", notes: "", dueDate: "2026-11-04",
            evidence: "Please send the meeting notes by Wednesday.")
    }
    private static var timedEvent: AssistantEventResult {
        var event = GoogleCalendarEvent(summary: "Design review with the product and engineering teams")
        event.start = .init(dateTime: "2026-11-05T09:30:00-05:00", timeZone: "America/New_York")
        event.end = .init(dateTime: "2026-11-05T10:15:00-05:00", timeZone: "America/New_York")
        event.location = "Video call · Meeting link in the source email"
        return .init(source: source, event: event,
            evidence: "The design review is Thursday, 5 November, from 9:30 to 10:15 AM New York time.")
    }
    private static var allDayEvent: AssistantEventResult {
        var event = GoogleCalendarEvent(summary: "Team planning day")
        event.start = .init(date: "2026-11-06")
        event.end = .init(date: "2026-11-07")
        event.location = "Vienna office"
        return .init(source: source, event: event, evidence: "Friday, 6 November is our team planning day.")
    }
    private static var undatedEvent: AssistantEventResult {
        .init(source: source, event: GoogleCalendarEvent(summary: "Customer workshop"),
            evidence: "We should arrange a customer workshop after the launch.",
            uncertainties: ["Time and location are still being discussed."])
    }

    private func capture<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, name: String,
                                       captureBottom: Bool = false, expandExcerpt: Bool = false,
                                       waitFor: String? = nil) async throws {
        let controller = NSHostingController(rootView: content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Tokens.Surface.primary).environment(\.colorScheme, scheme))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        if let waitFor {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while find(waitFor, in: controller.view) == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(find(waitFor, in: controller.view) != nil)
            try await Task.sleep(for: .milliseconds(150))
        }
        if expandExcerpt {
            let control = try #require(find("Source excerpt", in: controller.view, needsPress: true))
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let implementation = try #require(control.method(for: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            // AppKit's public -(BOOL)accessibilityPerformPress method has this ABI.
            #expect(unsafeBitCast(implementation, to: Press.self)(control, selector))
            try await Task.sleep(for: .milliseconds(150))
        }
        controller.view.layoutSubtreeIfNeeded()
        try attach(controller.view, name: name)
        if captureBottom, let scroll = scrollView(in: controller.view), let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutSubtreeIfNeeded()
            try attach(controller.view, name: name + "-bottom")
        }
    }

    private func attach(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func find(_ text: String, in root: Any, needsPress: Bool = false) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ item: Any) -> NSObject? {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func value(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
            if [value("accessibilityValue"), value("accessibilityLabel")].contains(where: { ($0 as? String)?.contains(text) == true }),
               !needsPress || object.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return object }
            let children = value("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let result = visit(child) { return result }
            }
            return nil
        }
        return visit(root)
    }
}

private actor AssistantVisualTasksService: TasksService {
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        .init(items: [.init(id: "work", title: "Work & projects"), .init(id: "personal", title: "Personal")])
    }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage { .init(items: []) }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask { throw GmailError.notFound }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask {
        throw GmailError.notFound
    }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws { throw GmailError.notFound }
}
