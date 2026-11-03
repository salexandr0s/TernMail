import AppKit
import GmailAPI
import MailStore
import ScreenCaptureKit
import SwiftUI
import Testing
import TernAI
import WebKit
@testable import Tern

/// Opt-in captures of the real workspace, with in-memory mail and calendar services.
@Suite(.serialized) @MainActor struct ReadmeScreenshots {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_README_SCREENSHOTS"] == "1"))
    func captureWorkspace() async throws {
        try #require(ReadmeDemoFixtures.isEnabled)
        let suite = "ReadmeScreenshots-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: DomainLogoPreferences.key)
        defaults.set("all", forKey: "mailColumnVisibility")
        defaults.set(false, forKey: MailWindowPreferences.hidesReaderKey)
        defaults.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        defaults.set(false, forKey: "sidebarFavoritesCollapsed")
        let previousCalendarMode = CalendarDefaults.store.object(forKey: CalendarDisplayMode.storageKey)
        CalendarDefaults.store.set(CalendarDisplayMode.week.rawValue, forKey: CalendarDisplayMode.storageKey)
        defer { CalendarDefaults.store.set(previousCalendarMode, forKey: CalendarDisplayMode.storageKey) }

        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        try await waitUntil { mailbox.accounts.count == 2 && mailbox.accounts.allSatisfy(\.hasSyncedOnce) }
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        try await waitUntil { mailbox.threads.count >= 14 }
        let selected = ThreadKey(accountID: "ui-audit", threadID: "demo-collection")
        mailbox.selectedThreadIDs = [selected]
        for owner in mailbox.accounts {
            for label in owner.labels where !label.isSystem {
                let icons = ["Projects": "briefcase", "Design": "lightbulb", "Finance": "creditcard",
                    "Read later": "book", "Travel": "airplane", "Friends": "person.2", "Receipts": "doc.text"]
                LabelAppearance.shared.setIcon(icons[label.name] ?? "tag", labelID: label.id, accountID: owner.account.id)
            }
        }
        await app.calendar.start()
        app.calendar.date = ReadmeDemoFixtures.date
        app.calendar.firstWeekday = 2
        app.calendar.workingHours.timeZoneIdentifier = "Europe/Vienna"
        await app.calendar.seedCalendarAudit()
        try await populateCalendar(app.calendar)
        app.destination = .mail

        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox)
            .environment(app).modifier(AddressAvatarEnvironment(app: app))
            .environment(\.workspaceToolbarID, "ReadmeWorkspace")
            .environment(\.locale, Locale(identifier: "en_US"))
            .defaultAppStorage(defaults))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.title = "Tern"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1500, height: 940))
        window.center()
        window.level = .floating
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.close() }

        for (name, appearance) in [("mail-light", NSAppearance.Name.aqua), ("mail-dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            mailbox.selectedThreadIDs = [selected]
            try await waitForMessage(in: controller.view)
            try await Task.sleep(for: .milliseconds(500))
            try await capture(window: window, name: name)
        }
        app.destination = .calendar
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .seconds(2))
        try await capture(window: window, name: "calendar")
        await app.calendar.stop()
        await mailbox.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_README_SCREENSHOTS"] == "1"))
    func captureAssistantAndTasks() async throws {
        try #require(ReadmeDemoFixtures.isEnabled)
        let suite = "ReadmeAssistant-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: DomainLogoPreferences.key)
        let app = AppModel()
        await app.start()
        let account = AccountRecord(id: "ui-audit", email: "alex@studio.example.invalid", displayName: "Studio",
            grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast,
            enabledFeatures: [AccountFeature.tasks.rawValue])

        for scenario in ReadmeAssistantScenario.allCases {
            let model = try await scenario.model(app: app, account: account, defaults: defaults)
            try await captureShowcase(AssistantView(model: model, onOpenSource: { _ in })
                .environment(app).defaultAppStorage(defaults),
                title: "Tern · Assistant", size: NSSize(width: 760, height: scenario == .events ? 680 : 860),
                name: scenario.rawValue)
            model.stop()
        }

        let tasks = GoogleTasksModel(defaults: defaults, loadAccounts: { [account] },
            service: { _ in ReadmeTasksService() }, enable: { _ in })
        await tasks.refresh()
        try #require(tasks.openTasks.count == 5)
        try await captureShowcase(GoogleTasksSidebar(model: tasks).defaultAppStorage(defaults),
            title: "Tern · Tasks", size: NSSize(width: 600, height: 680), name: "tasks")
        tasks.stop()
        await app.mailbox?.stop()
    }

    private func captureShowcase<Content: View>(_ content: Content, title: String, size: NSSize, name: String) async throws {
        let controller = NSHostingController(rootView: content
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, try #require(TimeZone(identifier: "Europe/Vienna"))))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(size)
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        try await capture(window: window, name: name)
    }

    private func populateCalendar(_ model: CalendarModel) async throws {
        let service = try #require(model.services["calendar-audit"])
        let week = try #require(model.calendar.dateInterval(of: .weekOfYear, for: model.date)?.start)
        let schedule = [(0, 11, "Collection photography", "work"), (0, 14, "Website handoff", "work"),
            (1, 11, "Autumn collection review", "work"), (1, 14, "Brand workshop", "work"),
            (2, 14, "Print proofs", "work"), (3, 10, "Studio open morning", "work"),
            (3, 14, "Editorial planning", "work"), (4, 10, "Launch checklist", "work"),
            (5, 10, "Ceramics workshop", "personal"), (6, 16, "Sunday dinner", "personal")]
        for (index, item) in schedule.enumerated() {
            let day = try #require(model.calendar.date(byAdding: .day, value: item.0, to: week))
            let start = try #require(model.calendar.date(bySettingHour: item.1, minute: 0, second: 0, of: day))
            let event = GoogleCalendarEvent(id: "readme-\(index)", summary: item.2,
                start: .init(date: start, timeZone: model.calendar.timeZone),
                end: .init(date: start.addingTimeInterval(3600), timeZone: model.calendar.timeZone))
            _ = try await service.insertEvent(calendarID: item.3, event: event, sendUpdates: "none")
        }
        await model.refreshCalendarAudit()
        #expect(model.events.count >= 16)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition())
    }

    private func waitForMessage(in root: NSView) async throws {
        func webViews(_ view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            for web in webViews(root) where !web.isLoading && !web.isHiddenOrHasHiddenAncestor {
                let text = try? await web.evaluateJavaScript("document.body.textContent", in: nil,
                    contentWorld: .defaultClient) as? String
                if text?.contains("The warmer palette works beautifully") == true { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("The fictional message body did not finish rendering before capture.")
        throw CocoaError(.coderValueNotFound)
    }

    private func capture(window: NSWindow, name: String) async throws {
        let data = try await Self.windowPixels(id: CGWindowID(window.windowNumber),
            width: Int(window.frame.width * 2), height: Int(window.frame.height * 2))
        Attachment.record(Array(data), named: name + ".png")
    }

    nonisolated private static func windowPixels(id: CGWindowID, width: Int, height: Int) async throws -> Data {
        // Limit capture to this process and this exact synthetic window. Unlike
        // view caching, ScreenCaptureKit includes vibrancy and WebKit surfaces.
        let content = try await SCShareableContent.currentProcess
        let target = try #require(content.windows.first { $0.windowID == id })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let pixels = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try #require(NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]))
    }
}

/// These captures exercise the production conversation and card views through
/// a local provider. No credentials or assistant requests leave the test host.
private enum ReadmeAssistantScenario: String, CaseIterable {
    case overview = "assistant", followUp = "follow-up", events

    @MainActor func model(app: AppModel, account: AccountRecord, defaults: UserDefaults) async throws -> AssistantModel {
        let connection = try Self.connection()
        let taskResult = result(for: "present_tasks")
        let eventResult = result(for: "present_events")
        let evidence = (toolNames.contains("present_tasks") ? taskResult.taskResults.map { ($0.source, $0.evidence) } : [])
            + (toolNames.contains("present_events") ? eventResult.eventResults.map { ($0.source, $0.evidence ?? "") } : [])
        let reads = evidence.enumerated().map { index, entry in
            (AIToolCall(id: "read-\(index)", namespace: "tern", name: "read_thread", arguments: "{}"),
             MailAssistantToolResult(data: .object([
                "account_id": .string(entry.0.accountID), "thread_id": .string(entry.0.threadID),
                "messages": .array([.object(["message_id": .string(entry.0.messageID ?? ""),
                    "thread_id": .string(entry.0.threadID), "text": .string(entry.1)])])
             ]), sources: [entry.0]))
        }
        let calls = try toolNames.map { name in
            AIToolCall(id: name, namespace: "tern", name: name, arguments: try presentationArguments(for: name).jsonString())
        }
        let rounds = reads.isEmpty ? [calls] : [reads.map { $0.0 }, calls]
        let provider = ReadmeAssistantProvider(rounds: rounds, answer: answer)
        let model = AssistantModel(app: app, connection: connection, provider: provider, defaults: defaults,
            context: { .init(accounts: [account], isAccountListReady: true, currentAccountIDs: [account.id],
                selectedThreads: [], accountInstances: [account.id: "readme-demo"],
                connectionRevision: connection.connectionRevision, canUsePlan: connection.canUsePlan) },
            makeTools: { _ in .init(definitions: ["read_thread", "present_emails"].map {
                .init(name: $0, description: "Present fictional demo results", parameters: .object(["type": .string("object")]))
            }, execute: { call in
                if let read = reads.first(where: { $0.0.id == call.id }) { return read.1 }
                return result(for: call.name)
            }) })
        model.setAccountEnabled(account.id, enabled: true)
        await model.refreshConnection()
        model.send(prompt)
        await model.waitForCurrentTurn()
        try #require(model.messages.last?.state == .completed)
        let message = try #require(model.messages.last)
        try #require(message.taskResults.count == (toolNames.contains("present_tasks") ? taskResult.taskResults.count : 0))
        try #require(message.eventResults.count == (toolNames.contains("present_events") ? eventResult.eventResults.count : 0))
        try #require(message.emailResults.count == (toolNames.contains("present_emails") ? result(for: "present_emails").emailResults.count : 0))
        return model
    }

    private func presentationArguments(for tool: String) -> AIJSON {
        let result = result(for: tool)
        if tool == "present_tasks" {
            return .object(["tasks": .array(result.taskResults.map { task in .object([
                "source_id": .string(task.source.id), "title": .string(task.title),
                "owner": task.owner.map(AIJSON.string) ?? .null, "notes": .string(task.notes),
                "due_date": task.dueDate.map(AIJSON.string) ?? .null, "evidence": .string(task.evidence)
            ]) })])
        }
        if tool == "present_events" {
            return .object(["events": .array(result.eventResults.map { value in .object([
                "source_id": .string(value.source.id), "proposal": .object([
                    "title": .string(value.title), "start": value.event.start?.dateTime.map(AIJSON.string) ?? .null,
                    "end": value.event.end?.dateTime.map(AIJSON.string) ?? .null, "all_day": .bool(false),
                    "time_zone": .string("Europe/Vienna"), "location": value.event.location.map(AIJSON.string) ?? .null,
                    "notes": .null, "evidence": value.evidence.map(AIJSON.string) ?? .null, "uncertainties": .array([])
                ])
            ]) })])
        }
        return .object([:])
    }

    private var toolNames: [String] {
        switch self {
        case .overview: ["present_tasks", "present_events", "present_emails"]
        case .followUp: ["present_emails"]
        case .events: ["present_events"]
        }
    }

    private var prompt: String {
        switch self {
        case .overview: "What needs my attention this week?"
        case .followUp: "Which emails need a follow-up from me?"
        case .events: "Find the upcoming events mentioned in my emails."
        }
    }

    private var answer: String {
        switch self {
        case .overview: "Three things to move forward: send the print proofs, review Thursday’s studio session, and reply to Maya."
        case .followUp: "## Waiting on you\nThese three conversations have a clear next step. Open an email to review the full thread before replying."
        case .events: "## Two dates to review\nI found these plans in your mail. Check the details, then review each event before adding it to your calendar."
        }
    }

    private static func source(_ id: String, _ title: String) -> AssistantSource {
        .init(accountID: "ui-audit", threadID: "demo-" + id, messageID: "demo-" + id + "-1", partID: nil, title: title)
    }

    private func result(for tool: String) -> MailAssistantToolResult {
        if tool == "present_tasks" {
            let source = Self.source("proofs", "Print proofs for the autumn collection")
            let task = AssistantTaskResult(source: source, title: "Send the final print proofs", owner: "You",
                notes: "Include the warmer cover option and the updated paper stock.", dueDate: "2026-11-04",
                evidence: "Could you send the final proofs by Wednesday so we can book the print run?")
            return .init(data: .null, sources: [source], taskResults: [task])
        }
        if tool == "present_events" {
            let first = Self.source("collection", "Autumn collection — final details")
            let second = Self.source("workshop", "A morning at the studio")
            var review = GoogleCalendarEvent(summary: "Autumn collection review")
            review.start = .init(dateTime: "2026-11-05T10:30:00+01:00", timeZone: "Europe/Vienna")
            review.end = .init(dateTime: "2026-11-05T11:15:00+01:00", timeZone: "Europe/Vienna")
            review.location = "Studio · Meeting room 2"
            var workshop = GoogleCalendarEvent(summary: "Brand workshop with the team")
            workshop.start = .init(dateTime: "2026-11-06T14:00:00+01:00", timeZone: "Europe/Vienna")
            workshop.end = .init(dateTime: "2026-11-06T15:30:00+01:00", timeZone: "Europe/Vienna")
            workshop.location = "Studio · Workshop space"
            let events = [AssistantEventResult(source: first, event: review,
                evidence: "Let’s review the collection on Thursday, 5 November, at 10:30 in meeting room 2."),
                AssistantEventResult(source: second, event: workshop,
                evidence: "Our brand workshop is Friday, 6 November, 14:00–15:30 at the studio.")]
            let selected = self == .overview ? Array(events.prefix(1)) : events
            return .init(data: .null, sources: selected.map(\.source), eventResults: selected)
        }
        let rows = [
            ("collection", "Maya Chen", "maya@studio.example.invalid", "Autumn collection — final details",
             "Confirm the warmer palette so Maya can send the artwork to print.", "Design", "#e7c7ef"),
            ("handoff", "Leo Martin", "leo@studio.example.invalid", "Website handoff is ready",
             "Review the handoff and reply with any missing assets before Friday.", "Projects", "#b6d7a8"),
            ("research", "Nora Williams", "nora@studio.example.invalid", "Interview notes and the next round",
             "Choose two interview slots and confirm who will join the next round.", "Research", "#a4c2f4")
        ]
        let emails = rows.map { id, name, address, subject, reason, label, color in
            AssistantEmailResult(source: Self.source(id, subject), senderName: name, senderEmail: address,
                subject: subject, snippet: reason, date: ReadmeDemoFixtures.date,
                isUnread: true, isStarred: id == "collection", messageCount: id == "collection" ? 3 : 2,
                accountEmail: "alex@studio.example.invalid",
                labels: [.init(accountID: "ui-audit", id: label, name: label, isSystem: false, backgroundColor: color)],
                reason: reason)
        }
        let selected = self == .overview ? Array(emails.prefix(1)) : emails
        return .init(data: .null, sources: selected.map(\.source), emailResults: selected)
    }

    @MainActor private static func connection() throws -> ChatGPTConnection {
        let now = Date.now
        let data = try JSONSerialization.data(withJSONObject: [
            "registration": ["clientID": "oaiapp_readme_demo", "hostID": "urn:uuid:8687c530-38cb-4d7d-ac63-0a235a03ba16",
                "subject": "readme-demo", "email": "alex@studio.example.invalid"],
            "account": ["subject": "readme-demo", "email": "alex@studio.example.invalid", "name": "Alex Morgan"],
            "accessToken": "not-a-real-credential", "idToken": "synthetic.id.token",
            "scopes": ["openid", "resource.invoke", "chatgpt.tokens.use.direct"],
            "receivedAt": now.timeIntervalSinceReferenceDate, "expiresAt": now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
        ])
        let credentials = try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
        var record = ChatGPTStoredConnection()
        record.hostID = credentials.registration.hostID
        record.registration = credentials.registration
        record.credentials = credentials
        return ChatGPTConnection(store: VolatileAIConnectionStore(data: try JSONEncoder().encode(record)),
            auth: .init(exchange: { _, _ in throw ChatGPTAuthError.unavailable },
                        refresh: { _ in throw ChatGPTAuthError.unavailable },
                        verify: { _ in throw ChatGPTAuthError.unavailable }, revoke: { _, _ in }), openBrowser: { _ in false })
    }
}

private actor ReadmeAssistantProvider: AIProvider {
    private var responses: [AIResponse]
    init(rounds: [[AIToolCall]], answer: String) {
        responses = rounds.map { calls in .init(output: calls.map { .object(["type": .string("function_call"), "call_id": .string($0.id),
            "namespace": .string($0.namespace), "name": .string($0.name), "arguments": .string($0.arguments)]) },
            text: "", toolCalls: calls) }
        responses.append(.init(output: [.object(["type": .string("message"), "role": .string("assistant"), "content": .array([
            .object(["type": .string("output_text"), "text": .string(answer)])])])], text: answer, toolCalls: []))
    }
    func models() async throws -> [AIModel] { [.init(id: "demo", displayName: "Demo model")] }
    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task { await self.reply(continuation) }
        }
    }
    private func reply(_ continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        guard !responses.isEmpty else { continuation.finish(throwing: AIProviderError.invalidResponse); return }
        continuation.yield(.completed(responses.removeFirst()))
        continuation.finish()
    }
}

private actor ReadmeTasksService: TasksService {
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        .init(items: [.init(id: "studio", title: "Studio · This week")])
    }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage {
        .init(items: [
            .init(id: "proofs", title: "Send the final print proofs", notes: "Include the warmer cover option and updated paper stock.", due: "2026-11-04T00:00:00Z"),
            .init(id: "maya", title: "Reply to Maya about the collection", notes: "Confirm the final palette and print quantities.", due: "2026-11-04T00:00:00Z"),
            .init(id: "review", title: "Prepare for Thursday’s design review", due: "2026-11-05T00:00:00Z"),
            .init(id: "assets", title: "Check the website handoff assets", due: "2026-11-06T00:00:00Z"),
            .init(id: "interviews", title: "Choose the next interview slots", notes: "Coordinate with Nora and the research team."),
            .init(id: "notes", title: "Share the workshop notes", status: "completed"),
            .init(id: "photos", title: "Upload the collection photos", status: "completed")])
    }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask { throw GmailError.notFound }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask { throw GmailError.notFound }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws { throw GmailError.notFound }
}
