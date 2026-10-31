import SwiftUI

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
