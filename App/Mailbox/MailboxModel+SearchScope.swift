import Foundation
import MailStore

/// A mailbox that search can stay inside: its name, and the Gmail operator
/// that limits a query to it.
struct MailboxSearchScope: Equatable {
    let title: String
    let restriction: String
}

/// Search covers all mail in the accounts in view. The scope bar can narrow
/// it to the selected mailbox or one account. The scope lives in the search,
/// so the sidebar shows no selection while results can come from outside the
/// selected mailbox.
extension MailboxModel {
    /// The selected mailbox as a search scope. Nil for mailboxes that hold
    /// all mail or that Gmail's query syntax can't name: All Mail, Snoozed,
    /// the Outbox, saved searches and labels with a quote in their name.
    var searchMailboxScope: MailboxSearchScope? {
        guard selectedSavedSearch == nil, let id = selectedLabelID,
              let restriction = searchRestriction(forLabel: id) else { return nil }
        // A nested label goes by its own name, as the sidebar shows it.
        let title = selectedMailboxTitle.split(separator: "/").last.map(String.init) ?? selectedMailboxTitle
        return MailboxSearchScope(title: title, restriction: restriction)
    }

    /// The accounts the scope bar can search alone, when search covers several.
    var searchAccountChoices: [AccountRecord] {
        let accounts = searchedAccounts.map(\.account)
        return accounts.count > 1 ? accounts : []
    }

    /// How many results the list shows: "12 results". The query stays out of
    /// the window's title and subtitle, which the Window menu and Mission
    /// Control show and saved window state can keep. The field shows it.
    var searchResultsSubtitle: String {
        let count = listItems.count
        guard count > 0 else { return search.gmail?.state == .loading ? "Searching…" : "No results" }
        if search.hasMoreResults { return "\(count.formatted())+ results" }
        return count == 1 ? "1 result" : "\(count.formatted()) results"
    }

    /// The sidebar's selection. Empty during a search, except for a saved
    /// search's own row. Choosing a mailbox ends the search, including the
    /// mailbox that was selected before it.
    var sidebarSelection: MailboxID? {
        get { search.isActive && selectedSavedSearch == nil ? nil : selectedMailbox }
        set {
            if let newValue, newValue == selectedMailbox {
                if selectedSavedSearch == nil { search.clear() }
            } else if newValue != nil || sidebarSelection != nil {
                selectedMailbox = newValue
            }
        }
    }

    private func searchRestriction(forLabel id: String) -> String? {
        switch id {
        case SystemLabel.inbox: return "in:inbox"
        case SystemLabel.starred: return "is:starred"
        case SystemLabel.important: return "is:important"
        case SystemLabel.unread: return "is:unread"
        case SystemLabel.sent: return "in:sent"
        case SystemLabel.draft: return "in:drafts"
        case SystemLabel.spam: return "in:spam"
        case SystemLabel.trash: return "in:trash"
        case "CATEGORY_PERSONAL": return "category:primary"
        default: break
        }
        if let category = InboxCategory.allCases.first(where: { $0.labelID == id }) {
            return "category:" + category.rawValue
        }
        // Gmail's syntax has no escapes, so a quote would end the quoted name.
        guard let label = label(id: id), !label.isSystem, !label.name.contains("\"") else { return nil }
        return "label:\"\(label.name)\""
    }
}
