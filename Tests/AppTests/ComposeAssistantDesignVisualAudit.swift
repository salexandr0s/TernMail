import AppKit
import MailStore
import MessageContent
import SwiftUI
import TernAI
import Testing
@testable import Tern

/// Opt-in native captures exercise production views with in-memory mail and a local model catalogue.
@Suite(.serialized) @MainActor struct ComposeAssistantDesignVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_COMPOSE_ASSISTANT_AUDIT_DIR"] != nil),
          arguments: [false, true])
    func composeAtMinimumSize(dark: Bool) async throws {
        let output = try outputDirectory()
        let suite = "ComposeAssistantDesignVisualAudit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: DomainLogoImages.preferenceKey)
        let cache = try MailCache.inMemory()
        let accounts = try AccountStore.inMemory()
        let account = Self.accounts[0]
        try await accounts.save(account)
        let outgoing = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: outgoing) }
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: outgoing, snoozeStore: accounts, syncEnabled: false)
        var draft = LocalDraft(id: "compose-design-audit", accountID: account.id, kind: .replyAll,
            content: .init(to: [.init(name: "Jordan Rivera", address: "jordan@example.invalid")],
                cc: [.init(name: "Product and Research", address: "product-research@example.invalid")],
                bcc: [.init(name: "Project archive", address: "archive@example.invalid")],
                subject: "Re: Review the delivery plan before Friday",
                body: ComposeDocument(plainText: "Hi Jordan,\n\nThanks for the review. I have added our next steps below.\n\nAlex"),
                fromAddress: account.email,
                signatureHTML: "<p><b>Alexandria Morgan</b><br>Product, Research and Engineering<br>Vienna office</p>"),
            rfcMessageID: "<compose-design-audit@example.invalid>", threadID: "t2", sourceMessageID: "m3",
            quotedHTML: "<blockquote>Please review the delivery plan before Friday.</blockquote>",
            quotedPlainText: String(repeating: "Please review the delivery plan and confirm the next steps before Friday.\n", count: 8),
            now: .now)
        draft.sendError = "The message could not be sent because the selected sender is no longer available. Choose another sender, check the recipients, and try again. Your draft and attachments are still here."
        let seededDraft = draft
        try await cache.write { transaction in
            try transaction.insertLocalDraft(seededDraft)
            _ = try transaction.addOutgoingAttachment(.init(localDraftID: seededDraft.id,
                filename: "Delivery plan and project review notes.pdf", mimeType: "application/pdf",
                size: 12_800, path: "synthetic-review.pdf"), now: .now)
        }
        let closer = ComposeWindowCloser()
        let host = Host(content: AnyView(ComposeView(localDraftID: draft.id, mailbox: mailbox,
            isEdited: .constant(false), closer: closer, onMove: { _ in Issue.record("Unexpected draft move") })
            .environment(AppModel()).defaultAppStorage(defaults)),
            size: NSSize(width: 480, height: 360), dark: dark)
        defer { host.close() }
        try await host.waitUntil { closer.model?.phase == .open && host.bodyEditor != nil }
        let model = try #require(closer.model)
        let editor = try #require(host.bodyEditor)
        let originalBody = editor.string
        let theme = dark ? "dark" : "light"
        try await host.capture("compose-minimum-collapsed-\(theme)", to: output)
        host.expectRequestedSize()
        try await host.reveal("compose-subject")
        host.expectWithinBounds("compose-subject")
        host.expectWithinBounds("compose-draft-status")
        try await host.reveal(try #require(editor.enclosingScrollView))
        host.expectViewWithinBounds(try #require(editor.enclosingScrollView))
        #expect(editor.enclosingScrollView?.contentView.bounds.height ?? 0 >= Tokens.Layout.editorMinHeight - 1)

        // Use the window's native key loop from To through Subject into the retained editor.
        let to = try #require(host.nativeViews.compactMap { $0 as? RecipientTokenField }
            .first { $0.accessibilityLabel() == "To" })
        try await host.reveal(to)
        to.selectText(nil)
        try await host.settle()
        let subject = try #require(host.nativeViews.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Subject" })
        var visitedSubject = false
        var responderTrace: [String] = []
        for _ in 0..<16 {
            responderTrace.append(String(describing: type(of: host.window.firstResponder)))
            if subject.currentEditor() === host.window.firstResponder { visitedSubject = true }
            if host.window.firstResponder === editor { break }
            let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: host.window.windowNumber, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            host.window.firstResponder?.keyDown(with: tab)
            try await host.settle()
        }
        #expect(visitedSubject, "Forward Tab must visit Subject after the recipients: \(responderTrace)")
        #expect(host.window.firstResponder === editor, "Forward Tab from Subject must reach the native message editor")
        #expect(host.bodyEditor === editor && editor.string == originalBody)

        try await host.reveal(label: "Signature")
        try host.press(label: "Signature")
        try await host.reveal(label: "Show Quoted Text")
        try host.press(label: "Show Quoted Text")
        try await host.settle()
        try await host.capture("compose-minimum-expanded-\(theme)", to: output)
        host.expectRequestedSize()
        host.expectWithinBounds("compose-draft-status")
        try await host.reveal("compose-edit-quote")
        host.expectWithinBounds("compose-edit-quote")
        try await host.reveal("compose-choose-signature")
        host.expectWithinBounds("compose-choose-signature")
        try await host.reveal(try #require(editor.enclosingScrollView))
        host.expectViewWithinBounds(try #require(editor.enclosingScrollView))
        #expect(host.bodyEditor === editor && editor.string == originalBody,
            "Expanding supplements must retain the native body editor and text")
        #expect(model.content.to == seededDraft.to && model.content.cc == seededDraft.cc && model.content.bcc == seededDraft.bcc)

        // Setup-required inputs cannot take focus, so opening Ask AI must reveal the bar itself.
        let selection = NSRange(location: 3, length: 7)
        editor.setSelectedRange(selection)
        try host.pressToolbar(label: "Compose Assistant")
        try await host.waitUntil { host.element("compose-assistant-bar") != nil }
        let prompt = try #require(host.nativeViews.compactMap { $0 as? ComposePromptTextView }.first)
        #expect(!prompt.isEditable, "This case must exercise the setup-required assistant")
        host.expectWithinBounds("compose-assistant-bar")
        host.expectViewWithinBounds(try #require(prompt.enclosingScrollView))
        #expect(host.bodyEditor === editor && editor.string == originalBody && editor.selectedRange() == selection,
            "Opening Ask AI must preserve the native message editor, text, and selection")
        try await host.capture("compose-minimum-assistant-\(theme)", to: output)
        host.close()
        await mailbox.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_COMPOSE_ASSISTANT_AUDIT_DIR"] != nil),
          arguments: [320, 380, 480], [false, true])
    func assistantScopeAndDraftAtMinimumSize(width: Int, dark: Bool) async throws {
        let output = try outputDirectory()
        let app = AppModel()
        let connection = try await Self.connectedFixture()
        let provider = CatalogueOnlyProvider()
        let context = Context(connection: connection)
        let model = AssistantModel(app: app, connection: connection, provider: provider,
            context: { context.value }, makeTools: { _ in
                .init(definitions: [], acknowledge: { _ in Issue.record("Unexpected tool acknowledgement") },
                      execute: { _ in Issue.record("Unexpected assistant tool call"); throw AIProviderError.invalidResponse })
            })
        defer { model.stop() }
        for account in Self.accounts { model.setAccountEnabled(account.id, enabled: true) }
        await model.refreshConnection()
        try #require(connection.canUsePlan && model.isModelReady && model.hasAssistantDataAccess)
        let size = NSSize(width: CGFloat(width), height: width == 480 ? 360 : 480)
        let host = Host(content: AnyView(AssistantView(model: model, onOpenSource: { _ in
            Issue.record("Unexpected source navigation")
        }, onClose: width == 480 ? nil : {}, isDetached: width == 480)), size: size, dark: dark)
        defer { host.close() }
        try await host.waitUntil { host.element("assistant.message") != nil }
        let theme = dark ? "dark" : "light"
        try await host.capture("assistant-ready-\(width)-\(theme)", to: output)
        host.expectRequestedSize()
        expectAssistantControls(host)

        let draft = "Compare the delivery dates.\nKeep the original estimate.\nCheck the review notes.\nList the unanswered questions.\nKeep the customer context.\nPrepare a reply for my review."
        model.composerText = draft
        context.currentAccountIDs = [Self.accounts[0].id]
        model.selectedScope = .currentAccount
        try #require(model.hasPendingScopeChange)
        try await host.settle()
        try await host.capture("assistant-pending-scope-\(width)-\(theme)", to: output)
        host.expectRequestedSize()
        expectAssistantControls(host)
        for identifier in ["assistant.scopeDecision", "assistant.scopeDetails", "assistant.scope.keepPrevious", "assistant.scope.startNewChat"] {
            host.expectWithinBounds(identifier)
        }
        if let details = host.element("assistant.scopeDetails") {
            #expect(details.frame(in: host.window).height <= Tokens.Assistant.compactScopeDetailsHeight + 1)
        }
        if let input = host.element("assistant.message") {
            let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .body))
            #expect(input.frame(in: host.window).height >= lineHeight * 2 - 1,
                "A multiline draft must retain at least two visible input lines")
        }
        try host.press("assistant.scope.keepPrevious")
        try await host.settle()
        #expect(!model.hasPendingScopeChange && model.usesPreviousMailScope)
        #expect(model.composerText == draft)
        host.expectWithinBounds("assistant.scope.reviewCurrent")
        try host.press("assistant.scope.reviewCurrent")
        try await host.settle()
        #expect(model.hasPendingScopeChange && model.composerText == draft)
        try host.press("assistant.scope.startNewChat")
        try await host.settle()
        #expect(!model.hasPendingScopeChange && !model.usesPreviousMailScope)
        #expect(model.composerText == draft && model.messages.isEmpty)
        expectAssistantControls(host)
    }

    private func expectAssistantControls(_ host: Host) {
        for identifier in ["assistant.scope", "assistant.model", "assistant.access", "assistant.message", "assistant.send", "assistant.transcript"] {
            host.expectWithinBounds(identifier)
        }
        if let transcript = host.element("assistant.transcript") {
            #expect(transcript.frame(in: host.window).height >= Tokens.Assistant.minimumTranscriptHeight - 1,
                "The transcript must retain at least 96 points of visible height")
        }
    }

    private func outputDirectory() throws -> URL {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "The native audit requires synthetic mail")
        let path = try #require(ProcessInfo.processInfo.environment["TERN_COMPOSE_ASSISTANT_AUDIT_DIR"])
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let accounts = [
        AccountRecord(id: "compose-assistant-audit", email: "alexandria.morgan.product-research-engineering@example.invalid",
            displayName: "Alexandria Morgan · Product, Research and Engineering", grantedScopes: [], addedAt: .distantPast),
        AccountRecord(id: "compose-assistant-audit-2", email: "international-project-coordination@example.invalid",
            displayName: "International Project Coordination", grantedScopes: [], addedAt: .distantPast),
    ]

    private static func connectedFixture() async throws -> ChatGPTConnection {
        let now = Date.now
        let data = try JSONSerialization.data(withJSONObject: [
            "registration": ["clientID": "oaiapp_tern_design_audit", "hostID": "urn:uuid:8687c530-38cb-4d7d-ac63-0a235a03ba16", "subject": "synthetic-design", "email": "audit@example.invalid"],
            "account": ["subject": "synthetic-design", "email": "audit@example.invalid", "name": "Design audit"],
            "accessToken": "synthetic-design-token", "refreshToken": "synthetic-design-refresh", "idToken": "synthetic.id.token",
            "scopes": ["openid", "resource.invoke", "chatgpt.tokens.use.direct"],
            "receivedAt": now.timeIntervalSinceReferenceDate,
            "expiresAt": now.addingTimeInterval(86_400).timeIntervalSinceReferenceDate,
        ])
        let credentials = try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
        var record = ChatGPTStoredConnection()
        record.hostID = credentials.registration.hostID
        record.registration = credentials.registration
        record.credentials = credentials
        let connection = ChatGPTConnection(store: VolatileAIConnectionStore(data: try JSONEncoder().encode(record)),
            auth: .init(exchange: { _, _ in Issue.record("Unexpected credential exchange"); throw ChatGPTAuthError.unavailable },
                refresh: { _ in Issue.record("Unexpected credential refresh"); throw ChatGPTAuthError.unavailable },
                verify: { _ in Issue.record("Unexpected credential verification"); throw ChatGPTAuthError.unavailable },
                revoke: { _, _ in Issue.record("Unexpected credential revocation"); throw ChatGPTAuthError.unavailable }),
            openBrowser: { _ in Issue.record("Unexpected browser authorization"); return false })
        await connection.recoverPendingConnection()
        return connection
    }

    @MainActor private final class Context {
        let connection: ChatGPTConnection
        var currentAccountIDs = Set(ComposeAssistantDesignVisualAudit.accounts.map(\.id))
        init(connection: ChatGPTConnection) { self.connection = connection }
        private static var accounts: [AccountRecord] { ComposeAssistantDesignVisualAudit.accounts }
        var value: AssistantContext {
            .init(accounts: Self.accounts, isAccountListReady: true, currentAccountIDs: currentAccountIDs,
                selectedThreads: [.init(accountID: Self.accounts[0].id, threadID: "t2")],
                accountInstances: Dictionary(uniqueKeysWithValues: Self.accounts.map { ($0.id, "synthetic-" + $0.id) }),
                connectionRevision: connection.connectionRevision, canUsePlan: connection.canUsePlan)
        }
    }

    private actor CatalogueOnlyProvider: AIProvider {
        func models() async throws -> [AIModel] {
            [.init(id: "synthetic-design-model", displayName: "ChatGPT · Extended reasoning model for product and engineering reviews")]
        }
        nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
            AsyncThrowingStream { continuation in
                Issue.record("Unexpected provider response request during a layout audit")
                continuation.finish(throwing: AIProviderError.invalidResponse)
            }
        }
    }

    @MainActor private final class Host {
        let window: NSWindow
        let requestedSize: NSSize
        private let controller: NSHostingController<AnyView>
        var nativeViews: [NSView] { descendants(controller.view) }
        var bodyEditor: ComposeTextView? { nativeViews.compactMap { $0 as? ComposeTextView }.first }

        init(content: AnyView, size: NSSize, dark: Bool) {
            requestedSize = size
            controller = NSHostingController(rootView: AnyView(content.environment(\.colorScheme, dark ? .dark : .light)))
            controller.sizingOptions = []
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentViewController = controller
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
        }

        func close() { window.contentViewController = nil; window.close() }
        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(6)
            repeat { try await settle() } while !condition() && ContinuousClock.now < deadline
            try #require(condition(), "The production view did not become ready")
        }
        func element(_ identifier: String) -> WorkspaceAuditAccessibility.Element? {
            WorkspaceAuditAccessibility.elements(in: controller.view).first { $0.identifier == identifier }
        }
        func expectWithinBounds(_ identifier: String) {
            guard let item = element(identifier) else { Issue.record("Missing audit element: \(identifier)"); return }
            #expect(item.isVisible(in: window), "\(identifier) must be fully inside the content bounds; frame: \(item.frame(in: window)), bounds: \(window.contentLayoutRect)")
        }
        func expectViewWithinBounds(_ view: NSView) {
            #expect(window.contentLayoutRect.insetBy(dx: -1, dy: -1).contains(view.convert(view.bounds, to: nil)),
                "The native editor must remain inside the content bounds")
        }
        func reveal(_ identifier: String) async throws {
            let item = try #require(element(identifier))
            try await reveal(windowRect: item.frame(in: window))
        }
        func reveal(label: String) async throws {
            let item = try #require(WorkspaceAuditAccessibility.elements(in: controller.view)
                .first { $0.label == label && $0.supportsPress })
            try await reveal(windowRect: item.frame(in: window))
        }
        func reveal(_ view: NSView) async throws {
            try await reveal(windowRect: view.convert(view.bounds, to: nil))
        }
        private func reveal(windowRect: NSRect) async throws {
            let scroll = try #require(nativeViews.compactMap { $0 as? NSScrollView }.first { scroll in
                guard let document = scroll.documentView, !(document is NSTextView) else { return false }
                return descendants(document).contains { $0 is ComposeTextView }
            })
            let document = try #require(scroll.documentView)
            document.scrollToVisible(document.convert(windowRect, from: nil))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
        }
        func expectRequestedSize() {
            #expect(abs(window.contentLayoutRect.width - requestedSize.width) <= 1)
            #expect(abs(window.contentLayoutRect.height - requestedSize.height) <= 1,
                "Intrinsic content must not enlarge the audit window beyond its requested minimum")
        }
        func press(_ identifier: String) throws {
            let control = try #require(element(identifier))
            #expect(control.isVisible(in: window), "\(identifier) must be visible before activation")
            try #require(control.supportsPress && control.press())
        }
        func press(label: String) throws {
            let control = try #require(WorkspaceAuditAccessibility.elements(in: controller.view)
                .first { $0.label == label && $0.supportsPress })
            #expect(control.isVisible(in: window), "\(label) must be visible before activation")
            try #require(control.press())
        }
        func pressToolbar(label: String) throws {
            let chrome = try #require(window.contentView?.superview)
            let control = try #require(WorkspaceAuditAccessibility.elements(in: chrome)
                .first { $0.label == label && $0.supportsPress })
            let frame = control.frame(in: window)
            #expect(!frame.isEmpty && NSRect(origin: .zero, size: window.frame.size).contains(frame),
                "The toolbar action must be inside this test window")
            try #require(control.press())
        }
        func capture(_ name: String, to output: URL) async throws {
            try await settle()
            let data = try await NativeWindowCapture.png(of: window)
            try data.write(to: output.appending(path: name + ".png"))
            Attachment.record(Array(data), named: name + ".png")
        }
        private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    }
}
