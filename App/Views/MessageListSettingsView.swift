import SwiftUI

struct MessageListSettingsView: View {
    var mailbox: MailboxModel? = nil
    @Bindable var preferences = MessageListPreferences.shared
    var body: some View {
        SettingsPage {
            Section("Appearance") {
                SettingsControlRow("Density") {
                    Picker("Density", selection: $preferences.density) {
                        ForEach(MailListDensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Compact density hides message previews.")
                }
                SettingsToggleRow("Show account badges", isOn: $preferences.showsAccountBadges)
                SettingsToggleRow("Show importance markers", isOn: $preferences.showsImportance)
                SettingsToggleRow("Show quick filters", isOn: $preferences.showsQuickFilters)
            }

            Section("Selection") {
                SettingsToggleRow("Group messages into conversations", isOn: $preferences.conversations)
                SettingsControlRow("After archiving or moving to Trash") {
                    Picker("After archiving or moving to Trash", selection: $preferences.nextSelection) {
                        ForEach(MailNextSelection.allCases) { Text(nextSelectionTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section("Swipe actions") {
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
                .padding(.vertical, Tokens.Space.s2)
            }

            Section("Sidebar") {
                SettingsToggleRow("Show More mailboxes", isOn: $preferences.showsMore)
                SettingsToggleRow("Total count for Starred", isOn: $preferences.starredTotal)
                SettingsToggleRow("Total count for Drafts", isOn: $preferences.draftsTotal)
                SettingsToggleRow("Unread count for Spam", isOn: $preferences.spamUnread)
            }
            if let mailbox { SidebarSettingsView(mailbox: mailbox) }
        }
    }

    /// The rule in full, in the list's own unit: conversations or messages.
    private func nextSelectionTitle(_ selection: MailNextSelection) -> String {
        let item = preferences.conversations ? "conversation" : "message"
        return switch selection {
        case .below: "Select the \(item) below"
        case .above: "Select the \(item) above"
        case .none: "Don't select another \(item)"
        }
    }

    /// Popups start at their column's leading edge, under its header.
    private func swipePicker(_ title: String, selection: Binding<MailSwipeAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MailSwipeAction.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
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
