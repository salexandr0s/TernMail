import SwiftUI

/// Compact windows keep global destinations in the native toolbar.
struct WorkspaceSectionToolbar: CustomizableToolbarContent {
    @Environment(\.showsWorkspaceRail) private var showsRail
    let section: WorkspaceSection
    let onSelect: (WorkspaceSection) -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "workspace.destination", placement: .navigation) {
            picker
        }
        .customizationBehavior(.disabled)
        .mailToolbarVisible(!showsRail)
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
