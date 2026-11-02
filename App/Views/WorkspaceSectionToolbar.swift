import SwiftUI

/// The section switcher after the sidebar button, in the same place in Mail,
/// Calendar and Attachments, with all sections visible at every window width.
struct WorkspaceSectionToolbar: CustomizableToolbarContent {
    let section: WorkspaceSection
    let onSelect: (WorkspaceSection) -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "workspace.destination", placement: .navigation) {
            picker
        }
        .customizationBehavior(.disabled)
    }

    // Keep the accessibility label on the picker itself.
    private var picker: some View {
        Picker("Section", selection: Binding(section, set: onSelect)) {
            ForEach(WorkspaceSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Show Mail (\(ShortcutCatalog.goMail.label)), Calendar (\(ShortcutCatalog.goCalendar.label)) "
            + "or Attachments (\(ShortcutCatalog.goAttachments.label))")
        .accessibilityLabel("Section")
        .accessibilityValue(section.title)
    }
}
