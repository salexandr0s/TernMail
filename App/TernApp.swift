import SwiftUI

@main
struct TernApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: 1200, height: 760)
        .commands { MailCommands(app: model) }
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
