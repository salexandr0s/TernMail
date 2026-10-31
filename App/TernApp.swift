import AppKit
import MailStore
import MessageContent
import SwiftUI

@main
struct TernApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        // One mailbox window: selection and undo live in the shared mailbox model.
        Window("Tern", id: RootView.sceneID) {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-audit-avatars"),
                   ProcessInfo.processInfo.arguments.contains("--ui-audit") {
                    AvatarAuditFixtures()
                } else { RootView() }
#else
                RootView()
#endif
            }
                .focusedSceneValue(\.isMainWindow, true)
                .modifier(MailURLHandling())
                .environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
                .task { await model.start() }
        }
        .defaultSize(width: Tokens.Layout.windowWidth, height: Tokens.Layout.windowHeight)
        .commands { MailCommands(app: model) }

        WindowGroup("Conversation", id: ConversationWindow.sceneID, for: MailLink.self) { $link in
            ConversationWindow(link: link).environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Layout.readableWidth, height: Tokens.Layout.shortcutsHeight)
        .commandsRemoved()

        WindowGroup("Original Message", id: OriginalMessageWindow.sceneID, for: MailLink.self) { $link in
            OriginalMessageWindow(link: link).environment(model)
        }
        .defaultSize(width: Tokens.Layout.readableWidth, height: Tokens.Layout.shortcutsHeight)
        .commandsRemoved()

        // One window per local draft. Opening a draft that has a window brings it forward.
        WindowGroup("New Message", id: ComposeWindow.sceneID, for: String.self) { $localDraftID in
            ComposeWindow(localDraftID: $localDraftID)
                .environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Layout.composeWidth, height: Tokens.Layout.composeHeight)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        // File > New Message replaces the New Window item this scene would add.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Settings.width, height: Tokens.Settings.height)
        .windowResizability(.contentMinSize)

        Window("Assistant", id: AssistantWindow.sceneID) {
            AssistantWindow(model: model.assistant, onOpenSource: model.openAssistantSource)
                .modifier(AddressAvatarEnvironment(app: model))
        }
        .defaultSize(width: Tokens.Layout.readableWidth, height: Tokens.Layout.shortcutsHeight)
        .windowResizability(.contentMinSize)

        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.sceneID) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        // Help opens it, so the Window menu doesn't list it too.
        .commandsRemoved()
    }
}

/// Owns the app model, so quitting can store open drafts and send messages
/// still waiting to go.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MailNotificationRouter.shared.install()
        MailScriptingBridge.shared.bind(model)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with every window closed brings the mailbox back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        model.showMainWindow()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let signedIn = model.mailbox != nil
        for (title, action, enabled) in [
            ("New Message", #selector(dockNewMessage), signedIn),
            ("Check for New Mail", #selector(dockCheckForNewMail), signedIn),
        ] as [(String, Selector, Bool)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("Inbox", #selector(dockShowInbox)), ("Calendar", #selector(dockShowCalendar))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = signedIn
            menu.addItem(item)
        }
        return menu
    }

    @objc private func dockNewMessage() { model.composeFromDock() }

    @objc private func dockCheckForNewMail() { model.mailbox?.syncNow() }

    @objc private func dockShowInbox() {
        model.showMainWindow()
        model.destination = .mail
        model.mailbox?.go(to: SystemLabel.inbox)
    }

    @objc private func dockShowCalendar() {
        model.showMainWindow()
        model.destination = .calendar
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !model.auth.handleRedirect(url) { model.mailURLs.receive(url) }
    }

    #if DEBUG
    /// Appearance checks affect only the synthetic audit app, never system preferences.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-audit") else { return }
        let highContrast = arguments.contains("--ui-audit-contrast")
        if arguments.contains("--ui-audit-light") {
            NSApp.appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastAqua : .aqua)
        } else if arguments.contains("--ui-audit-dark") {
            NSApp.appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
        }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.prepareToQuit()
            let waiting = await model.sendingDraftIDs()
            var sent = true
            if !waiting.isEmpty { sent = await model.sendWaitingMessages() }
            guard !sent else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let unsent = await model.sendingDraftIDs().count
            if unsent > 0 {
                let shouldQuit = Self.confirmQuit(unsent: unsent)
                if !shouldQuit { await model.cancelQuit() }
                sender.reply(toApplicationShouldTerminate: shouldQuit)
                return
            }
            // Nothing waits any more, so Gmail refused what didn't go out.
            let refused = await model.refusedDraftCount(among: waiting)
            let shouldQuit = refused == 0 || Self.confirmQuit(refused: refused)
            if !shouldQuit { await model.cancelQuit() }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    /// Asks before quitting with a refused message, which is open again and says why.
    private static func confirmQuit(refused count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Gmail didn't send your message" : "Gmail didn't send \(count) messages"
        alert.informativeText = count == 1
            ? "Review the error in the reopened message. If you quit, it stays unsent in the Outbox."
            : "Review the errors in the reopened messages. If you quit, they stay unsent in the Outbox."
        alert.addButton(withTitle: "Stay Open").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func confirmQuit(unsent count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Quit without sending your message?" : "Quit without sending \(count) messages?"
        alert.informativeText = "Tern can't reach Gmail. If you quit, "
            + (count == 1 ? "it will retry this message" : "it will retry these messages")
            + " the next time you open Tern."
        alert.addButton(withTitle: "Stay Open").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Picks the screen for the current sign-in phase.
struct RootView: View {
    /// The mailbox window's scene.
    static let sceneID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .onAppear {
                model.openMainWindow = {
                    NSApp.activate()
                    openWindow(id: Self.sceneID)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            openingState
        case .signedOut, .signInRequired:
            SignInView()
        case .signedIn:
            if let mailbox = model.mailbox {
                WorkspaceView(mailbox: mailbox)
            } else {
                openingState
            }
        case .failed(let message):
            TernEmptyState(
                title: "Couldn't open your mail",
                systemImage: "exclamationmark.triangle",
                message: message
            )
        }
    }

    private var openingState: some View {
        VStack(spacing: Tokens.Space.s4) {
            ProgressView()
                .controlSize(.small)
            Text("Opening your mail…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Surface.canvas)
    }
}
