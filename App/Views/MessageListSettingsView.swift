import SwiftUI

struct MessageListSettingsView: View {
    var mailbox: MailboxModel? = nil
    @Bindable var preferences = MessageListPreferences.shared
    var body: some View {
        SettingsPage {
            SettingsGroup("Appearance", systemImage: "list.bullet.rectangle") {
                SettingsControlRow("Density") {
                    Picker("Density", selection: $preferences.density) {
                        ForEach(MailListDensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Compact density hides message previews.")
                }
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Show account badges", isOn: $preferences.showsAccountBadges)
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Show importance markers", isOn: $preferences.showsImportance)
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Show quick filters", isOn: $preferences.showsQuickFilters)
            }

            SettingsGroup("Selection", systemImage: "cursorarrow") {
                SettingsToggleRow("Group messages into conversations", isOn: $preferences.conversations)
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsControlRow("After archiving or moving to Trash") {
                    Picker("Select next message", selection: $preferences.nextSelection) {
                        ForEach(MailNextSelection.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Choose the next message to select after an action.")
                }
            }

            SettingsGroup("Swipe actions", systemImage: "hand.draw") {
                Grid(alignment: .leading, horizontalSpacing: Tokens.Space.s3, verticalSpacing: Tokens.Space.s2) {
                    GridRow {
                        Text("")
                        Text("First action").font(.caption).foregroundStyle(.secondary)
                        Text("Second action").font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Leading")
                        swipePicker("Leading first", selection: $preferences.leadingFirst)
                        swipePicker("Leading second", selection: $preferences.leadingSecond)
                    }
                    GridRow {
                        Text("Trailing")
                        swipePicker("Trailing first", selection: $preferences.trailingFirst)
                        swipePicker("Trailing second", selection: $preferences.trailingSecond)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
            }

            SettingsGroup("Sidebar", systemImage: "sidebar.left") {
                SettingsToggleRow("Show More mailboxes", isOn: $preferences.showsMore)
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Total count for Starred", isOn: $preferences.starredTotal)
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Total count for Drafts", isOn: $preferences.draftsTotal)
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Unread count for Spam", isOn: $preferences.spamUnread)
            }
            if let mailbox { SidebarSettingsView(mailbox: mailbox) }
        }
    }

    private func swipePicker(_ title: String, selection: Binding<MailSwipeAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MailSwipeAction.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
    }
}

/// Root installs these controls in its existing View menu.
struct MessageListViewOptions: View {
    @Bindable var preferences = MessageListPreferences.shared
    var body: some View {
        Toggle("Conversations", isOn: $preferences.conversations)
        Toggle("Account Badges", isOn: $preferences.showsAccountBadges)
        Toggle("Importance Markers", isOn: $preferences.showsImportance)
        Toggle("Quick Filters", isOn: $preferences.showsQuickFilters)
    }
}
