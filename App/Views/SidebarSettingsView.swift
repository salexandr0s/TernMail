import GmailAPI
import MailStore
import SwiftUI

struct SidebarSettingsView: View {
    let mailbox: MailboxModel
    var body: some View {
        ForEach(mailbox.accounts, id: \.account.id) { owner in
            Section(mailbox.accountTitle(owner.account)) {
                DisclosureGroup("Inbox categories") {
                    VStack(spacing: 0) {
                        ForEach(InboxCategory.allCases, id: \.rawValue) { category in
                            SettingsAsyncToggleRow(SystemMailbox(labelID: category.labelID).title,
                                                   isOn: mailbox.accountPresentation[owner.account.id]?.inboxCategories.contains(category) == true) { enabled in
                                await mailbox.setCategory(category, enabled: enabled, accountID: owner.account.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
                DisclosureGroup("Label visibility") {
                    VStack(spacing: 0) {
                        let labels = owner.labels.filter { !$0.isSystem }
                        if labels.isEmpty {
                            Text("No custom labels")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Tokens.Space.s2)
                        }
                        ForEach(labels, id: \.id) { label in
                            SettingsControlRow(label.name) {
                                Picker(label.name, selection: Binding(LabelListVisibility(rawValue: label.labelListVisibility ?? "") ?? .show,
                                                                      set: { mailbox.setLabelVisibility(label, to: $0) })) {
                                    ForEach(LabelListVisibility.allCases, id: \.rawValue) { Text($0.sidebarTitle).tag($0) }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
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
