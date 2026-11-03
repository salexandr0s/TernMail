import AppKit
import GmailAPI
import MailStore
import SwiftUI
import Testing
import TernAI
@testable import Tern

/// Opt-in native captures of the utility sidebars with local data and services.
@Suite(.serialized) @MainActor struct SidebarDesignVisualAudit {
    private let audit = AssistantResultsVisualAudit()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func renderSidebars() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let suite = "SidebarDesignVisualAudit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountRecord(id: "sidebar-design-audit", email: "alex.morgan@studio.example.invalid",
            displayName: "Alex Morgan", grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast,
            enabledFeatures: [AccountFeature.tasks.rawValue])
        AccountProfileImages.shared.setAuditImage(SenderAccountLabel.auditImage, for: account.id)
        defer { AccountProfileImages.shared.remove(accountID: account.id) }
        let taskService = SidebarDesignTasksService(account: account)
        let tasks = GoogleTasksModel(defaults: defaults, loadAccounts: { [account] },
            service: { _ in taskService }, enable: { _ in })
        await tasks.refresh()
        let connection = try Self.connection()
        var selection: Set<ThreadKey> = [.init(accountID: account.id, threadID: "proposal")]
        let source = AssistantSource(accountID: account.id, threadID: "proposal", messageID: "m1", partID: nil,
            title: "Revised proposal and delivery dates for the November release")
        let assistant = AssistantModel(app: AppModel(), connection: connection,
            provider: SidebarDesignProvider(), defaults: defaults, context: {
                .init(accounts: [account], isAccountListReady: true, currentAccountIDs: [account.id],
                    selectedThreads: selection, accountInstances: [account.id: "fixture"],
                    connectionRevision: connection.connectionRevision, canUsePlan: connection.canUsePlan)
            }, makeTools: { _ in
                .init(definitions: MailAssistantTools.definitions, execute: { _ in
                    .init(data: .object(["body": .string("Please confirm the delivery dates by Friday.")]), sources: [source])
                })
            })
        await assistant.refreshConnection()
        assistant.setAccountEnabled(account.id, enabled: true)
        assistant.selectedScope = .selectedThreads
        assistant.send("Draft a reply to the selected conversation. Ask me if a decision or essential detail is missing.")
        await assistant.waitForCurrentTurn()
        #expect(assistant.messages.count == 2)
        #expect(assistant.messages.last?.state == .completed)
        defer { assistant.stop() }
        let avatarContext = AddressAvatarContext(profileAccountIDs: [account.email.lowercased(): account.id], identity: suite)
        for width in [320.0, 480.0] {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                try await audit.capture(GoogleTasksSidebar(model: tasks, onClose: {}, isActive: false),
                    size: NSSize(width: width, height: 860), scheme: scheme, name: "tasks-sidebar-\(suffix)")
                try await audit.capture(AssistantView(model: assistant, onOpenSource: { _ in }, onClose: {})
                    .environment(\.addressAvatarContext, avatarContext),
                    size: NSSize(width: width, height: 860), scheme: scheme, name: "chat-sidebar-\(suffix)")
            }
        }
        assistant.composerText = "Keep the reply brief."
        selection = [.init(accountID: account.id, threadID: "another-conversation")]
        assistant.refreshAccess()
        #expect(assistant.hasPendingScopeChange)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await audit.capture(AssistantView(model: assistant, onOpenSource: { _ in }, onClose: {})
                .environment(\.addressAvatarContext, avatarContext),
                size: NSSize(width: 320, height: 860), scheme: scheme,
                name: "chat-sidebar-pending-320-\(suffix)", increasedContrast: true)
        }
        assistant.startChatWithCurrentScope()
        assistant.composerText = ""
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await audit.capture(AssistantView(model: assistant, onOpenSource: { _ in }, onClose: {})
                .environment(\.addressAvatarContext, avatarContext),
                size: NSSize(width: 320, height: 860), scheme: scheme,
                name: "chat-sidebar-welcome-320-\(suffix)")
        }
        AccountProfileImages.shared.remove(accountID: account.id)
        try await audit.capture(GoogleTasksSidebar(model: tasks, onClose: {}, isActive: false),
            size: NSSize(width: 320, height: 860), scheme: .dark,
            name: "tasks-sidebar-initials-320-dark")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func renderMailCalendarTiles() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let sentAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9)))
        let evidence = "The design review is 5 November 2026, 10:00–11:00. The planning session has moved; its new date is still to be confirmed."
        let model = EmailCalendarModel()
        model.update(messages: [.init(id: "calendar-tile-audit", subject: "Design review and planning update",
            date: sentAt, text: evidence, allowsDateDetection: false)], addresses: [], timeZone: calendar.timeZone, now: sentAt)
        let dated = EmailCalendarItem(id: "interpreted:dated", messageID: "calendar-tile-audit", title: "Design review",
            evidence: evidence, kind: .proposed, event: GoogleCalendarEvent(summary: "Design review",
                start: .init(dateTime: "2026-11-05T10:00:00+01:00", timeZone: calendar.timeZone.identifier),
                end: .init(dateTime: "2026-11-05T11:00:00+01:00", timeZone: calendar.timeZone.identifier)))
        let undated = EmailCalendarItem(id: "interpreted:undated", messageID: "calendar-tile-audit", title: "Planning session",
            evidence: evidence, kind: .updated, event: GoogleCalendarEvent(summary: "Planning session"),
            uncertainties: ["Confirm the new date before updating the event."])
        #expect(model.restoreInterpretation([dated, undated], for: model.revision))
        model.markExisting(itemID: dated.id, calendarID: "audit", eventID: "design-review")
        #expect(model.visibleItems.count == 2)
        for width in [360.0, 720.0] {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                try await audit.capture(EmailCalendarSuggestionsView(model: model, calendar: calendar,
                    onReview: { _ in }, onOpenExisting: { _ in }, onRespond: { _, _ in })
                    .padding(Tokens.Space.s4), size: NSSize(width: width, height: 360), scheme: scheme,
                    name: "mail-calendar-tiles-\(suffix)")
            }
        }
    }

    private static func connection() throws -> ChatGPTConnection {
        let now = Date.now
        let data = try JSONSerialization.data(withJSONObject: [
            "registration": ["clientID": "oaiapp_sidebar_audit", "hostID": "urn:uuid:8687c530-38cb-4d7d-ac63-0a235a03ba16", "subject": "audit", "email": "alex@example.invalid"],
            "account": ["subject": "audit", "email": "alex@example.invalid", "name": "Alex Morgan"],
            "accessToken": "synthetic-audit-token", "refreshToken": "synthetic-audit-refresh", "idToken": "synthetic.id.token",
            "scopes": ["openid", "resource.invoke", "chatgpt.tokens.use.direct"],
            "receivedAt": now.timeIntervalSinceReferenceDate,
            "expiresAt": now.addingTimeInterval(86_400).timeIntervalSinceReferenceDate
        ])
        let credentials = try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
        var record = ChatGPTStoredConnection()
        record.hostID = credentials.registration.hostID
        record.registration = credentials.registration
        record.credentials = credentials
        return ChatGPTConnection(store: VolatileAIConnectionStore(data: try JSONEncoder().encode(record)),
            auth: .init(exchange: { _, _ in throw ChatGPTAuthError.unavailable },
                refresh: { _ in throw ChatGPTAuthError.unavailable },
                verify: { _ in throw ChatGPTAuthError.unavailable }, revoke: { _, _ in }))
    }
}

private actor SidebarDesignProvider: AIProvider {
    private var hasRead = false

    func models() async throws -> [AIModel] { [.init(id: "audit", displayName: "GPT-6-Luna")] }

    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.completed(await response()))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func response() -> AIResponse {
        if !hasRead {
            hasRead = true
            let call = AIToolCall(id: "read-proposal", namespace: "tern", name: "read_thread", arguments: "{}")
            return .init(output: [.object(["type": .string("function_call"), "call_id": .string(call.id),
                "namespace": .string(call.namespace), "name": .string(call.name), "arguments": .string(call.arguments)])],
                text: "", toolCalls: [call])
        }
        let text = "The team needs your approval on the revised delivery dates by **Friday, 6 November**. Would you like to confirm the proposed dates or ask for more time?"
        return .init(output: [.object(["type": .string("message"), "role": .string("assistant"), "content": .array([
            .object(["type": .string("output_text"), "text": .string(text)])
        ])])], text: text, toolCalls: [])
    }
}

private actor SidebarDesignTasksService: TasksService {
    let account: AccountRecord
    init(account: AccountRecord) { self.account = account }

    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        .init(items: [.init(id: "list", title: "My Tasks"), .init(id: "work", title: "Work & projects")])
    }

    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage {
        let requests = [
            TaskCreationRequest(title: "Your flight from ZRH to LHR", notes: "5 Nov 2026 · 17:00–18:50 CET",
                dueDate: "2026-11-05", source: .init(accountID: account.id, threadID: "flight", subject: "Thank you for booking with us | From Zurich to London")),
            TaskCreationRequest(title: "Review the revised proposal and confirm delivery dates", notes: "Owner: Alex Morgan",
                dueDate: "2026-11-06", source: .init(accountID: account.id, threadID: "proposal", subject: "Revised proposal and delivery dates for the November release")),
            TaskCreationRequest(title: "Submit account verification information", notes: "Check the documents before uploading.",
                dueDate: "2026-11-13", source: .init(accountID: account.id, threadID: "verification", subject: "We need some information from you"))
        ]
        let tasks = try requests.enumerated().map { index, request in
            let draft = try request.draft(email: account.email)
            return GoogleTask(id: "task-\(index)", title: draft.title, notes: draft.notes,
                due: request.dueDate.map { $0 + "T00:00:00Z" })
        }
        return .init(items: tasks + [.init(id: "completed", title: "Send the meeting notes", status: "completed")])
    }

    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask { throw GmailError.notFound }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask { throw GmailError.notFound }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws { throw GmailError.notFound }
}
