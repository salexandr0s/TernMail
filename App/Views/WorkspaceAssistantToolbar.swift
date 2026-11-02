import SwiftUI

enum WorkspacePanel { case assistant, tasks }

/// Tasks and Assistant occupy the same trailing sidebar.
struct WorkspaceAssistantToolbar: CustomizableToolbarContent {
    let isAssistantPresented: Bool
    let onToggleAssistant: () -> Void
    var isAssistantAvailable = true
    var isTasksPresented = false
    var onToggleTasks: () -> Void = {}

    var body: some CustomizableToolbarContent {
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "workspace.tasks", placement: .primaryAction) {
            Button(action: onToggleTasks) {
                Label("Google Tasks", systemImage: isTasksPresented ? "checklist.checked" : "checklist")
            }
            .help(isTasksPresented ? "Close Google Tasks" : "Open Google Tasks")
            .accessibilityLabel(isTasksPresented ? "Close Google Tasks sidebar" : "Open Google Tasks sidebar")
            .accessibilityValue(isTasksPresented ? "Open" : "Closed")
            .accessibilityIdentifier("workspace-tasks")
        }
        ToolbarItem(id: "workspace.assistant", placement: .primaryAction) {
            AssistantLauncher(isPresented: isAssistantPresented, onToggle: onToggleAssistant)
                .disabled(!isAssistantAvailable)
                .help(isAssistantAvailable
                    ? (isAssistantPresented ? "Close assistant sidebar" : "Ask about your mail")
                    : "Assistant is available in Mail and Calendar")
        }
    }
}
