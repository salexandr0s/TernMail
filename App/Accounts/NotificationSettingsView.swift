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
        SettingsPage {
            VStack(alignment: .leading, spacing: 0) {
                permissionRow
                if let error = notifications.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red)
                        .padding(.horizontal, Tokens.Space.s4)
                        .padding(.bottom, Tokens.Space.s2)
                }
            }
            .settingsSurface()

            SettingsGroup("New mail", systemImage: "envelope.badge") {
                if preferences.orderedRecords.isEmpty {
                    SettingsNote("Add an account to choose which messages trigger notifications.", systemImage: "person.crop.circle.badge.plus")
                        .padding(.horizontal, Tokens.Space.s4)
                        .padding(.vertical, Tokens.Space.s2)
                } else {
                    SettingsControlRow("Account") {
                        Picker("Account", selection: $selectedAccount) {
                            ForEach(preferences.orderedRecords) { account in Text(account.email).tag(account.id) }
                        }
                        .labelsHidden()
                    }
                    if !selectedAccount.isEmpty {
                        Divider().padding(.horizontal, Tokens.Space.s4)
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
                            .labelsHidden()
                        }
                    }
                }
            }

            SettingsGroup("Sounds and actions", systemImage: "bell") {
                SettingsControlRow("Notification action") {
                    Picker("Notification action", selection: $action) {
                        ForEach(MailNotificationAction.allCases, id: \.rawValue) { action in Text(action.title).tag(action.rawValue) }
                    }
                    .labelsHidden()
                }
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Play a sound", isOn: $sound)
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Unread count in menu bar", detail: "Shows the number of unread Inbox messages.", isOn: $menuBar)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                SettingsNote("The Dock counts unread Inbox messages for the active profile. Closing the mailbox keeps mail running; quitting Tern stops notifications.", systemImage: "app.badge")
                SettingsNote("Profiles limit alerts to their accounts. Set notification hours in Profiles, or choose a Tern profile in System Settings → Focus → Focus Filters.", systemImage: "person.2")
            }
            if let error = preferences.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
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
            SettingsControlRow("Notifications are off", detail: "Enable Tern in macOS Notification Settings.") {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityLabel("Open macOS Notification Settings")
            }
        case .allowed:
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body).foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Notifications allowed")
                Spacer(minLength: Tokens.Space.s3)
                Button("Send Test") { Task { await notifications.sendTestNotification() } }
                    .accessibilityLabel("Send test notification")
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s2)
        }
    }
}
