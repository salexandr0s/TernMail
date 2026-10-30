import GmailAPI
import MailStore
import SwiftUI

struct SidebarSettingsView: View {
    let mailbox: MailboxModel
    var body: some View {
        ForEach(mailbox.accounts, id: \.account.id) { owner in
            Section("Inbox Categories — \(mailbox.accountTitle(owner.account))") {
                ForEach(InboxCategory.allCases, id: \.rawValue) { category in
                    Toggle(category.rawValue.capitalized, isOn: Binding(
                        get: { mailbox.accountPresentation[owner.account.id]?.inboxCategories.contains(category) == true },
                        set: { enabled in Task { await mailbox.setCategory(category, enabled: enabled, accountID: owner.account.id) } }
                    ))
                }
            }
            Section("Label Visibility — \(mailbox.accountTitle(owner.account))") {
                ForEach(owner.labels.filter { !$0.isSystem }, id: \.id) { label in
                    Picker(label.name, selection: Binding(
                        get: { LabelListVisibility(rawValue: label.labelListVisibility ?? "") ?? .show },
                        set: { mailbox.setLabelVisibility(label, to: $0) }
                    )) {
                        ForEach(LabelListVisibility.allCases, id: \.rawValue) { Text($0.sidebarTitle).tag($0) }
                    }
                }
            }
        }
    }
}

extension LabelListVisibility {
    var sidebarTitle: String {
        switch self {
        case .show: "Show"
        case .hide: "Hide"
        case .showIfUnread: "Show if Unread"
        }
    }
}
