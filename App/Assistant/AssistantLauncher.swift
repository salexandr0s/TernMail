import SwiftUI

/// What the main window shows. The toolbar's picker and the Go menu switch it.
enum WorkspaceSection: String, CaseIterable, Identifiable {
    case mail, calendar, attachments
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .mail: "envelope"
        case .calendar: "calendar"
        case .attachments: "paperclip"
        }
    }
}

/// Opens the assistant beside the reader without changing the window's size.
struct AssistantLauncher: View {
    let isPresented: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
        }
        .help(isPresented ? "Close assistant sidebar" : "Ask about your mail")
        .accessibilityLabel(isPresented ? "Close assistant sidebar" : "Open assistant sidebar")
        .accessibilityValue(isPresented ? "Open" : "Closed")
    }
}

/// The section pop-up the Calendar toolbar shows beside the sidebar button.
/// Mail and Attachments switch sections from the sidebar's Library rows; the
/// mail toolbar has no room for it in a 960-point window.
struct WorkspaceSectionToolbar: CustomizableToolbarContent {
    let section: WorkspaceSection
    let onSelect: (WorkspaceSection) -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "workspace.destination", placement: .navigation) {
            Picker("Section", selection: Binding(get: { section }, set: { onSelect($0) })) {
                ForEach(WorkspaceSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            .pickerStyle(.menu)
            .labelStyle(.iconOnly)
            .help("Show Mail, Calendar or Attachments")
            .accessibilityLabel("Section")
            .accessibilityValue(section.title)
        }
    }
}

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
