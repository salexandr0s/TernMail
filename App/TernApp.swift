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
            ComposeWindow(localDraftID: localDraftID)
                .environment(model)
        }
        .defaultSize(width: 720, height: 600)
        // File > New Message replaces the New Window item this scene would add.
        .commandsRemoved()
    }
}

/// Owns the app model, so quitting can send messages still waiting to go.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waiting = model.waitingSendCount
        guard waiting > 0 else { return .terminateNow }
        Task {
            let sent = await model.sendWaitingMessages()
            let unsent = model.waitingSendCount
            sender.reply(toApplicationShouldTerminate: sent || Self.confirmQuit(unsent: unsent > 0 ? unsent : waiting))
        }
        return .terminateLater
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
