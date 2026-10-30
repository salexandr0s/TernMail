import SwiftUI

/// Opens the assistant beside the reader without changing the window's size.
struct AssistantLauncher: View {
    let isPresented: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
                .labelStyle(.iconOnly)
                .frame(width: Tokens.Control.icon, height: Tokens.Control.icon)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(isPresented ? "Close assistant sidebar" : "Ask about your mail")
        .accessibilityLabel(isPresented ? "Close assistant sidebar" : "Open assistant sidebar")
        .accessibilityValue(isPresented ? "Open" : "Closed")
    }
}

/// Shared trailing controls for the active Mail or Calendar toolbar.
struct WorkspaceAssistantToolbar: CustomizableToolbarContent {
    @Environment(AppModel.self) private var app
    let isAssistantPresented: Bool
    let onToggleAssistant: () -> Void
    var isAssistantAvailable = true

    var body: some CustomizableToolbarContent {
        let nextDestination: WorkspaceDestination = app.destination == .mail ? .calendar : .mail
        ToolbarItem(id: "workspace.destination", placement: .primaryAction) {
            Button {
                app.destination = nextDestination
            } label: {
                Label("Switch to \(nextDestination.title)",
                    systemImage: nextDestination == .calendar ? "calendar" : "envelope")
            }
            .labelStyle(.iconOnly)
            .help("Switch to \(nextDestination.title)")
        }
        ToolbarItem(id: "workspace.assistant", placement: .primaryAction) {
            AssistantLauncher(isPresented: isAssistantPresented, onToggle: onToggleAssistant)
        }
        .mailToolbarVisible(isAssistantAvailable)
    }
}
