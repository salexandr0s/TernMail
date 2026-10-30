import SwiftUI

struct MessageListSettingsView: View {
    var mailbox: MailboxModel? = nil
    @Bindable var preferences = MessageListPreferences.shared
    var body: some View {
        Form {
            Section("Message list") {
                Toggle("Group messages into conversations", isOn: $preferences.conversations)
                Picker("Density", selection: $preferences.density) {
                    ForEach(MailListDensity.allCases) { Text($0.title).tag($0) }
                }
                Picker("After archiving or trashing, select", selection: $preferences.nextSelection) {
                    ForEach(MailNextSelection.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Account badges", isOn: $preferences.showsAccountBadges)
                Toggle("Importance markers", isOn: $preferences.showsImportance)
                Toggle("Quick filters", isOn: $preferences.showsQuickFilters)
            }
            Section("Swipe actions") {
                swipePicker("Leading first", selection: $preferences.leadingFirst)
                swipePicker("Leading second", selection: $preferences.leadingSecond)
                swipePicker("Trailing first", selection: $preferences.trailingFirst)
                swipePicker("Trailing second", selection: $preferences.trailingSecond)
            }
            Section("Sidebar") {
                Toggle("Show More mailboxes", isOn: $preferences.showsMore)
                Toggle("Total count for Starred", isOn: $preferences.starredTotal)
                Toggle("Total count for Drafts", isOn: $preferences.draftsTotal)
                Toggle("Unread count for Spam", isOn: $preferences.spamUnread)
            }
            if let mailbox { SidebarSettingsView(mailbox: mailbox) }
        }.formStyle(.grouped)
    }

    private func swipePicker(_ title: String, selection: Binding<MailSwipeAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MailSwipeAction.allCases) { Text($0.title).tag($0) }
        }
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
