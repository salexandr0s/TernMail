import MailStore

/// The sidebar mailboxes expanded to show each account. `@AppStorage` keeps
/// the IDs sorted and joined by commas.
struct SidebarExpansion: RawRepresentable {
    static let storageKey = "sidebarExpandedMailboxes"
    static let initial = SidebarExpansion(ids: [SystemLabel.inbox])

    var ids: Set<String>

    init(ids: Set<String>) {
        self.ids = ids
    }

    init(rawValue: String) {
        ids = Set(rawValue.split(separator: ",").map(String.init))
    }

    var rawValue: String { ids.sorted().joined(separator: ",") }
}
