import SwiftUI

struct MessageListSettingsView: View {
    var mailbox: MailboxModel? = nil
    @Bindable var preferences = MessageListPreferences.shared
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        SettingsPage {
            Section("Appearance") {
                MailListAppearancePreview(preferences: preferences)
                    .accessibilityIdentifier("settings.messageList.preview")
                SettingsControlRow("Density", detail: "Compact hides message previews.") {
                    Picker("Density", selection: $preferences.density) {
                        ForEach(MailListDensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsToggleRow("Show account badges", detail: "Identifies accounts in mailboxes that combine their mail.", isOn: $preferences.showsAccountBadges)
                SettingsToggleRow("Show importance markers", isOn: $preferences.showsImportance)
                SettingsToggleRow("Show quick filters", isOn: $preferences.showsQuickFilters)
            }

            Section("Selection") {
                SettingsToggleRow("Group messages into conversations", isOn: $preferences.conversations)
                SettingsControlRow("After Archive or Trash") {
                    Picker("After archiving or moving to Trash", selection: $preferences.nextSelection) {
                        ForEach(MailNextSelection.allCases) { Text(nextSelectionTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                SettingsControlRow("First action") {
                    swipePicker("\(leadingSwipeTitle), first action", selection: $preferences.leadingFirst)
                }
                SettingsControlRow("Second action") {
                    swipePicker("\(leadingSwipeTitle), second action", selection: $preferences.leadingSecond)
                }
            } header: {
                Label(leadingSwipeTitle, systemImage: layoutDirection == .leftToRight ? "arrow.right" : "arrow.left")
            } footer: {
                Text("Swipe a message to reveal these actions, then choose one.")
            }
            Section {
                SettingsControlRow("First action") {
                    swipePicker("\(trailingSwipeTitle), first action", selection: $preferences.trailingFirst)
                }
                SettingsControlRow("Second action") {
                    swipePicker("\(trailingSwipeTitle), second action", selection: $preferences.trailingSecond)
                }
            } header: {
                Label(trailingSwipeTitle, systemImage: layoutDirection == .leftToRight ? "arrow.left" : "arrow.right")
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

    private var leadingSwipeTitle: String { layoutDirection == .leftToRight ? "Swipe right" : "Swipe left" }
    private var trailingSwipeTitle: String { layoutDirection == .leftToRight ? "Swipe left" : "Swipe right" }

    /// The rule in full, in the list's own unit: conversations or messages.
    private func nextSelectionTitle(_ selection: MailNextSelection) -> String {
        let item = preferences.conversations ? "conversation" : "message"
        return switch selection {
        case .below: "Select the \(item) below"
        case .above: "Select the \(item) above"
        case .none: "Don't select another \(item)"
        }
    }

    /// Each action has a full row so long menu choices fit at the minimum window width.
    private func swipePicker(_ title: String, selection: Binding<MailSwipeAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MailSwipeAction.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
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
