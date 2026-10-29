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
        .defaultSize(width: 1200, height: 760)
        .commands { MailCommands(app: model) }

        // One window per local draft. Opening a draft that has a window brings it forward.
        WindowGroup("New Message", id: ComposeWindow.sceneID, for: String.self) { $localDraftID in
            ComposeWindow(localDraftID: $localDraftID)
                .environment(model)
        }
        .defaultSize(width: 720, height: 600)
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
            ? "It's open again and says why. If you quit, it stays in the Outbox and isn't sent."
            : "They're open again and say why. If you quit, they stay in the Outbox and aren't sent."
        alert.addButton(withTitle: "Stay Open")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func confirmQuit(unsent count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Quit without sending your message?" : "Quit without sending \(count) messages?"
        alert.informativeText = "Tern can't reach Gmail right now. If you quit, "
            + (count == 1 ? "the message goes" : "the messages go")
            + " out the next time you open Tern."
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
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut, .signInRequired:
            SignInView()
        case .signedIn:
            if let mailbox = model.mailbox {
                MainView(mailbox: mailbox)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .failed(let message):
            ContentUnavailableView(
                "Tern Couldn't Open Its Data",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}
