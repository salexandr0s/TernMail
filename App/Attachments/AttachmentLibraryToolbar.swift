import MailStore
import SwiftUI

/// How the attachment library lays out its files.
enum AttachmentLibraryViewMode: String, CaseIterable {
    case list, grid

    private static let defaultsKey = "attachments.viewMode"

    /// The layout chosen last, kept between launches.
    static var saved: Self {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .list }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .list: "List"
        case .grid: "Grid"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
}

/// The toolbar items the main window shows while the attachment library is in
/// front: the List and Grid switch and the sort menu. The window's search
/// field searches the library, so the library has no field of its own.
struct AttachmentLibraryToolbar: CustomizableToolbarContent {
    @Bindable var state: AttachmentLibraryToolbarState

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "library.viewMode", placement: .automatic) {
            Picker("View", selection: $state.viewMode) {
                ForEach(AttachmentLibraryViewMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show attachments as a list or a grid")
        }
        ToolbarItem(id: "library.sort", placement: .automatic) {
            // A bare menu picker shows no title in the toolbar, so a menu holds it.
            Menu {
                Picker("Sort By", selection: $state.sort) {
                    ForEach(AttachmentLibrarySort.allCases, id: \.self) { sort in
                        Text(sort.menuTitle).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort attachments")
            .accessibilityValue(state.sort.menuTitle)
        }
    }
}

private extension AttachmentLibrarySort {
    /// Menu items use title case, unlike the sentence-case titles in MailStore.
    var menuTitle: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .filename: "Filename"
        case .sender: "Sender"
        case .largest: "Largest First"
        case .smallest: "Smallest First"
        }
    }
}
