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
    @AppStorage(NotificationPolicy.dockBadgeKey) private var dockBadge = true

    var body: some View {
        SettingsPage {
            Section {
                permissionRow
                if let error = notifications.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(Tokens.Status.error)
                }
            }

            Section {
                if preferences.orderedRecords.isEmpty {
                    SettingsNote("Add an account to choose which messages trigger notifications.", systemImage: "person.crop.circle.badge.plus")
                } else {
                    SettingsControlRow("Account") {
                        Picker("Account", selection: $selectedAccount) {
                            ForEach(preferences.orderedRecords) { account in Text(account.email).tag(account.id) }
                        }
                        .fixedSize()
                    }
                    if !selectedAccount.isEmpty {
                        SettingsControlRow("Notify me about") {
                            Picker("Notify me about", selection: Binding(get: { preferences.preferences(for: selectedAccount).notificationRule }, set: { rule in
                                let id = selectedAccount
                                Task { await preferences.update(id) { $0.notificationRule = rule } }
                            })) {
                                Text("Off").tag(MailNotificationRule.off)
                                Text("Inbox").tag(MailNotificationRule.inbox)
                                Text("Inbox without categories").tag(MailNotificationRule.inboxWithoutCategories)
                                Text("All Mail").tag(MailNotificationRule.allMail)
                            }
                            .fixedSize()
                        }
                    }
                }
            } header: {
                Text("New mail")
            } footer: {
                Text("Profiles limit alerts to their accounts. Set notification hours in Profiles, or choose a Tern profile in System Settings → Focus → Focus Filters.")
            }

            Section("Sounds and actions") {
                SettingsControlRow("Notification action", detail: "Listed first on new-mail notifications. Reply and the other actions follow.") {
                    Picker("Notification action", selection: $action) {
                        ForEach(MailNotificationAction.allCases, id: \.rawValue) { action in Text(action.title).tag(action.rawValue) }
                    }
                    .fixedSize()
                }
                SettingsToggleRow("Play a Sound", isOn: $sound)
            }

            Section {
                SettingsToggleRow("Badge App Icon", detail: "Shows the unread Inbox count on Tern's Dock icon.", isOn: $dockBadge)
                SettingsToggleRow("Unread Count in Menu Bar", detail: "Shows the number of unread Inbox messages.", isOn: $menuBar)
            } header: {
                Text("Unread counts")
            } footer: {
                Text("Counts follow the active profile. Closing the mailbox keeps mail running; quitting Tern stops notifications.")
            }

            if let error = preferences.error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Tokens.Status.error)
                }
            }
        }
        .task { await notifications.refreshPermission() }
        .onChange(of: preferences.orderedRecords.map(\.id), initial: true) { _, ids in
            if !ids.contains(selectedAccount) { selectedAccount = ids.first ?? "" }
        }
    }

    @ViewBuilder private var permissionRow: some View {
        switch notifications.permission {
        case .notRequested:
            SettingsControlRow("Allow notifications", detail: "Let Tern notify you when new mail arrives.") {
                Button("Allow…") { Task { await notifications.requestPermission() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Allow notifications")
            }
        case .denied:
            SettingsControlRow("Notifications are off", detail: "Turn on Tern in macOS Notification settings.") {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityLabel("Open macOS Notification settings")
            }
        case .allowed:
            LabeledContent {
                Button("Send Test") { Task { await notifications.sendTestNotification() } }
                    .accessibilityLabel("Send test notification")
            } label: {
                Label {
                    Text("Notifications allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Status.success)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
