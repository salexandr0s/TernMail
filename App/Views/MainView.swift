import SwiftUI

struct MainView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section("Mailboxes") {
                    Label("Inbox", systemImage: "tray")
                    Label("Starred", systemImage: "star")
                    Label("Sent", systemImage: "paperplane")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            ContentUnavailableView(
                "No Messages",
                systemImage: "tray",
                description: Text("Sign in to load your mail.")
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        } detail: {
            ContentUnavailableView("No Conversation Selected", systemImage: "envelope")
        }
    }
}
