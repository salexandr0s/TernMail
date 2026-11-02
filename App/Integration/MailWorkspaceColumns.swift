import AppKit
import MailStore
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
    var sidebarWidth = Tokens.Layout.sidebarWidth
    private(set) var isCompact = false
    var isPopoverPresented = false
    var searchFocusRequest = 0
    /// Supplied by the retained library presentation, including while its page is hidden.
    private(set) var sidebarModel: AttachmentLibraryModel?
    /// The window's search field while the library shows; the library mirrors it.
    var searchText = ""
    /// The toolbar's sort menu; the library mirrors it like the search text.
    var sort = AttachmentLibrarySort.newest
    var viewMode = AttachmentLibraryViewMode.saved {
        didSet { AttachmentLibraryViewMode.saved = viewMode }
    }
    var showsSidebar: Bool { !isCompact && columnVisibility == .all }

    var sidebarToggle: SidebarToggle {
        SidebarToggle(isVisible: isCompact ? isPopoverPresented : showsSidebar, toggle: toggleSidebar)
    }

    func toggleSidebar() {
        if isCompact { isPopoverPresented.toggle() }
        else { columnVisibility = showsSidebar ? .detailOnly : .all }
    }

    func updateCompact(_ compact: Bool) {
        isCompact = compact
        if !compact { isPopoverPresented = false }
    }

    func attachSidebarModel(_ model: AttachmentLibraryModel) {
        guard sidebarModel !== model else { return }
        isPopoverPresented = false
        sidebarModel = model
    }

    func detachSidebarModel(_ model: AttachmentLibraryModel) {
        guard sidebarModel === model else { return }
        isPopoverPresented = false
        sidebarModel = nil
    }
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
