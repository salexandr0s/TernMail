import SwiftUI

@main
struct TernApp: App {
    @State private var model = AppModel()

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
