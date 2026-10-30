import AppKit
import Observation
import SwiftUI

enum MailWindowPreferences {
    static let hidesReaderKey = "hideViewingPane"
}

/// The fixed workspace toolbar controls the library while its view is mounted.
@MainActor @Observable
final class AttachmentLibraryToolbarState {
    var columnVisibility = NavigationSplitViewVisibility.all
    var searchFocusRequest = 0
    var showsSidebar: Bool { columnVisibility == .all }

    func toggleSidebar() { columnVisibility = showsSidebar ? .detailOnly : .all }
}

/// The two-column layout really removes the reader's native split column.
struct MailWorkspaceColumns<Sidebar: View, Content: View, Detail: View>: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let showsReader: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        Group {
            if showsReader {
                NavigationSplitView(columnVisibility: $columnVisibility, sidebar: sidebar, content: content, detail: detail)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility, sidebar: sidebar, detail: content)
            }
        }
        .onChange(of: showsReader) { _, visible in
            if visible, columnVisibility == .detailOnly { columnVisibility = .doubleColumn }
            else if !visible, columnVisibility == .doubleColumn { columnVisibility = .detailOnly }
        }
    }
}
