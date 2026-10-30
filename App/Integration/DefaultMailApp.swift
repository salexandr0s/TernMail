import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class DefaultMailApp {
    private(set) var isDefault = false
    private(set) var isChanging = false
    var error: String?

    func refresh() {
        guard let url = URL(string: "mailto:check@example.invalid") else { return }
        isDefault = NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    func makeDefault() async {
        guard !isChanging else { return }
        isChanging = true
        error = nil
        defer { isChanging = false }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
            refresh()
        } catch { self.error = "macOS couldn't change the default mail app." }
    }
}

struct DefaultMailAppView: View {
    @State private var model = DefaultMailApp()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Default mail app")
                Text(model.error ?? (model.isDefault ? "Email links open in Tern." : "Choose Tern to open email links."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.isDefault ? "Default Mail App" : "Make Default") { Task { await model.makeDefault() } }
                .disabled(model.isDefault || model.isChanging)
        }
        .task { model.refresh() }
    }
}
