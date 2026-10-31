import SwiftUI

/// The assistant button at the trailing end of the toolbar.
struct WorkspaceAssistantToolbar: CustomizableToolbarContent {
    let isAssistantPresented: Bool
    let onToggleAssistant: () -> Void
    var isAssistantAvailable = true

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "workspace.assistant", placement: .primaryAction) {
            AssistantLauncher(isPresented: isAssistantPresented, onToggle: onToggleAssistant)
        }
        .mailToolbarVisible(isAssistantAvailable)
    }
}
