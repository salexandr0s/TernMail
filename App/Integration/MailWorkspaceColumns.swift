import AppKit
import Observation
import SwiftUI

enum MailWindowPreferences {
    static let hidesReaderKey = "hideViewingPane"
    /// The customizable toolbar's identifier. A new name starts from the
    /// default items, so configurations saved before the system search field
    /// don't pin the old search item.
    static let toolbarID = "Tern.Workspace"
}

/// The fixed workspace toolbar controls the library while its view is mounted.
@MainActor @Observable
final class AttachmentLibraryToolbarState {
    var columnVisibility = NavigationSplitViewVisibility.all
    var searchFocusRequest = 0
    /// The window's search field while the library shows; the library mirrors it.
    var searchText = ""
    var showsSidebar: Bool { columnVisibility == .all }

    func toggleSidebar() { columnVisibility = showsSidebar ? .detailOnly : .all }
}

extension NavigationSplitViewVisibility {
    /// The value as `UserDefaults` keeps it between launches.
    init?(storageValue: String) {
        switch storageValue {
        case "all": self = .all
        case "doubleColumn": self = .doubleColumn
        case "detailOnly": self = .detailOnly
        default: return nil
        }
    }

    var storageValue: String {
        switch self {
        case .all: "all"
        case .doubleColumn: "doubleColumn"
        case .detailOnly: "detailOnly"
        default: ""
        }
    }
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
