import AppKit
import SwiftUI

@main
struct TernApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        // One mailbox window: selection and undo live in the shared mailbox model.
        Window("Tern", id: "main") {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: Tokens.Layout.windowWidth, height: Tokens.Layout.windowHeight)
        .commands { MailCommands(app: model) }

        // One window per local draft. Opening a draft that has a window brings it forward.
        WindowGroup("New Message", id: ComposeWindow.sceneID, for: String.self) { $localDraftID in
            ComposeWindow(localDraftID: $localDraftID)
                .environment(model)
        }
        .defaultSize(width: 720, height: 600)
        .windowResizability(.contentMinSize)
        // File > New Message replaces the New Window item this scene would add.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
        }

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
                sender.reply(toApplicationShouldTerminate: Self.confirmQuit(unsent: unsent))
                return
            }
            // Nothing waits any more, so Gmail refused what didn't go out.
            let refused = await model.refusedDraftCount(among: waiting)
            sender.reply(toApplicationShouldTerminate: refused == 0 || Self.confirmQuit(refused: refused))
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
        alert.addButton(withTitle: "Stay Open")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func confirmQuit(unsent count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Quit without sending your message?" : "Quit without sending \(count) messages?"
        alert.informativeText = "Tern can't reach Gmail. If you quit, "
            + (count == 1 ? "it will retry this message" : "it will retry these messages")
            + " the next time you open Tern."
        alert.addButton(withTitle: "Stay Open")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Picks the screen for the current sign-in phase.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            openingState
        case .signedOut, .signInRequired:
            SignInView()
        case .signedIn:
            if let mailbox = model.mailbox {
                MainView(mailbox: mailbox)
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
