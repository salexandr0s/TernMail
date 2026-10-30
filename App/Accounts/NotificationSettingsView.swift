import AppKit
import MailStore
import SwiftUI

struct NotificationSettingsView: View {
    @Bindable var preferences: AccountPreferencesModel
    @Bindable var notifications: MailNotificationCoordinator
    @State private var selectedAccount = ""
    @AppStorage(MailNotificationAction.storageKey) private var action = MailNotificationAction.archive.rawValue
    @AppStorage(NotificationPolicy.soundKey) private var sound = true
    @AppStorage(NotificationPolicy.menuBarCountKey) private var menuBar = false

    var body: some View {
        ScrollView {
            Form {
                Section("New mail") {
                    Picker("Account", selection: $selectedAccount) {
                        ForEach(preferences.orderedRecords) { account in Text(account.email).tag(account.id) }
                    }
                    if !selectedAccount.isEmpty {
                        Picker("Notify me", selection: Binding(get: { preferences.preferences(for: selectedAccount).notificationRule }, set: { rule in
                            let id = selectedAccount
                            Task { await preferences.update(id) { $0.notificationRule = rule } }
                        })) {
                            Text("Off").tag(MailNotificationRule.off)
                            Text("Inbox").tag(MailNotificationRule.inbox)
                            Text("Inbox without categories").tag(MailNotificationRule.inboxWithoutCategories)
                            Text("All Mail").tag(MailNotificationRule.allMail)
                        }
                    }
                    Picker("Notification action", selection: $action) {
                        ForEach(MailNotificationAction.allCases, id: \.rawValue) { action in Text(action.title).tag(action.rawValue) }
                    }
                    Toggle("Play notification sound", isOn: $sound)
                    Toggle("Show unread Inbox count in menu bar", isOn: $menuBar)
                    Text("The Dock shows the unread Inbox count for the active profile. Closing the mailbox window keeps mail running; Quit stops it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("macOS permission") {
                    switch notifications.permission {
                    case .notRequested:
                        Button("Allow Notifications…") { Task { await notifications.requestPermission() } }
                    case .denied:
                        Text("Notifications are off in System Settings.").foregroundStyle(.secondary)
                        Button("Open Notification Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    case .allowed: Text("Notifications are allowed.").foregroundStyle(.secondary)
                    }
                    Button("Send Test Notification") { Task { await notifications.sendTestNotification() } }
                        .disabled(notifications.permission != .allowed)
                    if let error = notifications.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("Profiles and Focus") {
                    Text("A selected profile limits alerts to its accounts. Set notification hours in Profiles. You can also choose a Tern profile in System Settings → Focus → Focus Filters.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .task { await notifications.refreshPermission() }
        .onChange(of: preferences.orderedRecords.map(\.id), initial: true) { _, ids in
            if !ids.contains(selectedAccount) { selectedAccount = ids.first ?? "" }
        }
    }
}
