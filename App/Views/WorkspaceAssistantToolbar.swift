import SwiftUI

/// The assistant button at the trailing end of the toolbar, in a capsule of
/// its own so it doesn't read as part of search.
struct WorkspaceAssistantToolbar: CustomizableToolbarContent {
    let isAssistantPresented: Bool
    let onToggleAssistant: () -> Void
    var isAssistantAvailable = true

    var body: some CustomizableToolbarContent {
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "workspace.assistant", placement: .primaryAction) {
            AssistantLauncher(isPresented: isAssistantPresented, onToggle: onToggleAssistant)
                .disabled(!isAssistantAvailable)
                .help(isAssistantAvailable
                    ? (isAssistantPresented ? "Close assistant sidebar" : "Ask about your mail")
                    : "Assistant is available in Mail and Calendar")
        }
    }
}
