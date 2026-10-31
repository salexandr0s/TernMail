import SwiftUI

/// The assistant button at the trailing end of the toolbar, spaced apart so
/// it doesn't read as part of the search field.
struct WorkspaceAssistantToolbar: CustomizableToolbarContent {
    let isAssistantPresented: Bool
    let onToggleAssistant: () -> Void
    var isAssistantAvailable = true

    var body: some CustomizableToolbarContent {
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "workspace.assistant", placement: .primaryAction) {
            AssistantLauncher(isPresented: isAssistantPresented, onToggle: onToggleAssistant)
        }
        .mailToolbarVisible(isAssistantAvailable)
    }
}
