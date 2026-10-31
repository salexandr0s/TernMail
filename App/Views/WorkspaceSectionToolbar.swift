import SwiftUI

/// The section switcher after the sidebar button, in the same place in Mail,
/// Calendar and Attachments. A compact window shows it as a pop-up menu to
/// leave room for search and the assistant.
struct WorkspaceSectionToolbar: CustomizableToolbarContent {
    let section: WorkspaceSection
    var isCompact = false
    let onSelect: (WorkspaceSection) -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "workspace.destination", placement: .navigation) {
            if isCompact { picker(.menu) } else { picker(.segmented) }
        }
        .customizationBehavior(.disabled)
    }

    // The label sits on the picker itself; on a group around it, the toolbar's
    // pop-up button reaches VoiceOver unnamed.
    private func picker(_ style: some PickerStyle) -> some View {
        Picker("Section", selection: Binding(section, set: onSelect)) {
            ForEach(WorkspaceSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
            }
        }
        .pickerStyle(style)
        .labelStyle(.iconOnly)
        .help("Show Mail (\(ShortcutCatalog.goMail.label)), Calendar (\(ShortcutCatalog.goCalendar.label)) "
            + "or Attachments (\(ShortcutCatalog.goAttachments.label))")
        .accessibilityLabel("Section")
        .accessibilityValue(section.title)
    }
}
