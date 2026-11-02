import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Opt-in native inspection of message editors and scope review with synthetic content.
@Suite(.serialized) @MainActor struct ReviewFixesVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_REVIEW_FIXES_AUDIT_DIR"] != nil))
    func renderMessageEditors() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_REVIEW_FIXES_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, scheme, width) in [("light", ColorScheme.light, 620.0), ("dark", .dark, 780.0)] {
            try await capture(ComposeQuoteEditor(text: "On Monday, Jordan wrote:\n\nPlease keep the agenda and remove the older discussion before forwarding.\n\nAgenda\n• Project timing\n• Review responsibilities") { _ in true },
                width: width, scheme: scheme, name: "quote-editor-" + name, directory: directory)
            try await capture(ComposeSignatureEditor(html: "<p><strong>Alex Morgan</strong><br>Product design<br><a href=\"https://example.invalid\">Example Studio</a></p>") { _ in },
                width: width, scheme: scheme, name: "signature-editor-" + name, directory: directory)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_REVIEW_FIXES_AUDIT_DIR"] != nil))
    func renderScopeReview() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_REVIEW_FIXES_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let account = AccountRecord(id: "scope-audit", email: "alex@example.invalid", displayName: "Work",
                                    grantedScopes: [], addedAt: .now)
        var selection: Set<ThreadKey> = [.init(accountID: account.id, threadID: "original")]
        let model = AssistantModel(app: AppModel(), connection: ChatGPTConnection(store: VolatileAIConnectionStore()), context: {
            AssistantContext(accounts: [account], isAccountListReady: true, currentAccountIDs: [account.id],
                selectedThreads: selection, accountInstances: [account.id: "fixture"], connectionRevision: 1, canUsePlan: true)
        })
        model.setAccountEnabled(account.id, enabled: true)
        model.selectedScope = .selectedThreads
        model.composerText = "Please help me reply to the project update."
        selection = [.init(accountID: account.id, threadID: "linked-source")]
        model.refreshAccess()
        #expect(model.hasPendingScopeChange)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            try await capture(VStack(spacing: 0) {
                AssistantScopeNotice(model: model)
                Text(model.composerText).padding().frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }, width: 430, scheme: scheme, name: "assistant-scope-review-" + name, directory: directory)
        }
    }

    private func capture<Content: View>(_ content: Content, width: Double, scheme: ColorScheme,
                                       name: String, directory: String) async throws {
        let controller = NSHostingController(rootView: content
            .frame(width: width, height: 440, alignment: .topLeading)
            .background(Tokens.Surface.primary)
            .environment(\.colorScheme, scheme))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: width, height: 440))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }
}
