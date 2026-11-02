import AppKit
import MailStore
import SwiftUI

/// First-run choices use the same preferences as Settings and take effect immediately.
struct OnboardingPreferencesStep: View {
    @Environment(AppModel.self) private var app
    @AppStorage(ComposePreferences.defaultAccountKey) private var defaultAccount = ""
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds
    @AppStorage(ReadingPreferences.blockImagesKey) private var blocksImages = true
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @State private var requestingNotifications = false
    @State private var notificationError: String?

    private var accounts: [AccountRecord] {
        app.accountPreferences?.orderedRecords ?? app.mailbox?.accounts.map(\.account) ?? []
    }

    private var isPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-audit") || AssistantRuntimeEnvironment.isTestHost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            VStack(spacing: 0) {
                OnboardingPreferenceRow("Send new messages from", detail: "Automatic follows the mailbox or recipient.", symbol: "paperplane") {
                    Picker("Default sending account", selection: $defaultAccount) {
                        Text("Automatic").tag("")
                        ForEach(accounts) { account in
                            Text(account.email).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                    .help(accounts.first(where: { $0.id == defaultAccount })?.email ?? "Automatic")
                    .accessibilityIdentifier("onboarding.defaultAccount")
                }
                rowDivider
                OnboardingPreferenceRow("Undo Send", detail: "Give yourself time to take a message back.", symbol: "arrow.uturn.backward") {
                    Picker("Undo Send delay", selection: $undoSendDelay) {
                        ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("onboarding.undoSend")
                }
                rowDivider
                OnboardingPreferenceRow("Block remote images", detail: "Load images only when you choose to.", symbol: "hand.raised") {
                    Toggle("Block remote images", isOn: $blocksImages)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("onboarding.blockImages")
                }
                rowDivider
                OnboardingPreferenceRow("Single-key shortcuts", detail: "Use letter keys to act on mail while you aren't typing.", symbol: "keyboard") {
                    Toggle("Single-key shortcuts", isOn: $usesSingleKeys)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("onboarding.singleKeyShortcuts")
                }
                rowDivider
                notificationRow
            }
            .ternSurface()

            if let notificationError {
                SettingsErrorLabel(notificationError)
            }
            Text("You can change these choices in Settings at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermission() }
        }
        .onChange(of: accounts.map(\.id), initial: true) { _, ids in
            if !defaultAccount.isEmpty, !ids.contains(defaultAccount) { defaultAccount = "" }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, Tokens.Space.s4 + Tokens.Space.s8 + Tokens.Space.s3)
    }

    @ViewBuilder private var notificationRow: some View {
        if let notifications = app.mailNotifications {
            OnboardingPreferenceRow("New mail notifications", detail: notificationDetail(notifications.permission), symbol: "bell") {
                if requestingNotifications {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Requesting notification permission")
                } else {
                    switch notifications.permission {
                    case .allowed:
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Tokens.Status.success)
                    case .denied:
                        Button("Open Settings…", action: openNotificationSettings)
                            .accessibilityLabel("Open macOS Notification settings")
                            .disabled(isPreview)
                    case .notRequested:
                        Button("Enable…") { requestNotifications(notifications) }
                            .accessibilityLabel("Enable new mail notifications")
                            .accessibilityHint("macOS will ask for permission to show notifications.")
                            .disabled(isPreview)
                    }
                }
            }
        } else {
            OnboardingPreferenceRow("New mail notifications", detail: "Connect a Google account to enable notifications.", symbol: "bell") {
                Text("Not enabled").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func notificationDetail(_ permission: MailNotificationPermission) -> String {
        switch permission {
        case .notRequested: "Get an alert when new mail arrives."
        case .denied: "Allow Tern in macOS Notification settings."
        case .allowed: "Choose which mail alerts you in Settings."
        }
    }

    private func refreshPermission() async {
        guard !isPreview else { return }
        await app.mailNotifications?.refreshPermission()
    }

    private func requestNotifications(_ notifications: MailNotificationCoordinator) {
        guard !isPreview, !requestingNotifications else { return }
        requestingNotifications = true
        notificationError = nil
        notifications.error = nil
        Task {
            await notifications.requestPermission()
            notificationError = notifications.error
            requestingNotifications = false
        }
    }

    private func openNotificationSettings() {
        guard !isPreview,
              let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct OnboardingPreferenceRow<Control: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let control: Control

    init(_ title: String, detail: String, symbol: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(Tokens.Space.s4)
    }
}
