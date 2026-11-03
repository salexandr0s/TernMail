import AppKit
import SwiftUI

struct FollowUpsSettingsView: View {
    @Bindable var preferences: FollowUpPreferences
    @Bindable var followUps: FollowUpsModel
    var automation: AutomaticFollowUpCoordinator? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRequestingPermission = false
    @State private var permissionError: String?

    var body: some View {
        SettingsPage {
            remindersSection
            draftsSection
            notificationsSection
        }
        .task { await refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshPermission() } }
        }
    }

    private var remindersSection: some View {
        Section {
            SettingsToggleRow("Remind me about unanswered sent mail",
                detail: "Automatically track sent conversations that are waiting for a reply.",
                isOn: $preferences.automaticRemindersEnabled)
                .accessibilityIdentifier("follow-ups-automatic-reminders")
            SettingsControlRow("Remind me after", detail: "Days since your last message, from 1 to 365.") {
                HStack(spacing: Tokens.Space.s2) {
                    TextField("Reminder delay in days", value: $preferences.delayDays, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Tokens.Space.s16)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Reminder delay in days")
                        .accessibilityHint("Enter a number from 1 to 365.")
                        .accessibilityIdentifier("follow-ups-delay-days")
                    Text("days")
                        .accessibilityHidden(true)
                    Stepper("Adjust reminder delay", value: $preferences.delayDays, in: 1...365)
                        .labelsHidden()
                        .accessibilityLabel("Adjust reminder delay")
                        .accessibilityIdentifier("follow-ups-delay-stepper")
                }
                .accessibilityElement(children: .contain)
            }
            .accessibilityElement(children: .contain)
            .disabled(!preferences.automaticRemindersEnabled)
            if let automation {
                if automation.isChecking {
                    HStack(spacing: Tokens.Space.s2) {
                        ProgressView().controlSize(.small)
                        Text("Checking sent conversations…")
                    }
                }
                if let error = automation.errorMessage {
                    HStack(alignment: .top, spacing: Tokens.Space.s3) {
                        SettingsErrorLabel(error)
                        Spacer(minLength: 0)
                        Button("Retry Check") { Task { await automation.start() } }
                            .disabled(automation.isChecking)
                    }
                }
            }
        } header: {
            Text("Automatic reminders")
        } footer: {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(automation?.coverageMessage ?? FollowUpPreferences.coverageMessage)
                Text("Existing overdue conversations appear quietly in Today; new reminders follow your chosen delay.")
            }
        }
    }

    private var draftsSection: some View {
        Section {
            SettingsToggleRow("Draft follow-ups automatically",
                detail: "Prepare a draft when an automatic reminder becomes due. Runs only while automatic reminders are on.",
                isOn: $preferences.automaticDraftsEnabled)
                .disabled(!preferences.automaticRemindersEnabled)
                .accessibilityIdentifier("follow-ups-automatic-drafts")
            if let error = automation?.draftErrorMessage { SettingsErrorLabel(error) }
            SettingsControlRow("Assistant access",
                detail: "Requires a connected AI provider and assistant access for the conversation's account.") {
                Button("Assistant Settings…") {
                    SettingsNavigationRequests.shared.request(.assistant)
                }
            }
        } header: {
            Text("Automatic drafts")
        } footer: {
            Text("Tern sends conversation context to your selected AI provider to prepare each draft. Turning this on does not change your account access permissions. Review and send drafts yourself; Tern never sends them automatically.")
        }
    }

    private var notificationsSection: some View {
        Section {
            notificationPermissionRow
            if let permissionError { SettingsErrorLabel(permissionError) }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Tern checks reminders on this Mac while it is running and when it resumes. Due items remain in Today and Waiting for even when notifications are off.")
        }
    }

    @ViewBuilder private var notificationPermissionRow: some View {
        switch followUps.notificationPermission {
        case .notRequested:
            SettingsControlRow("Allow notifications", detail: "Show a macOS notification when a follow-up is due.") {
                Button("Allow…") { Task { await requestPermission() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequestingPermission)
                    .accessibilityLabel("Allow follow-up notifications")
                    .accessibilityIdentifier("follow-ups-settings-allow-notifications")
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
            Label {
                Text("Notifications allowed")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tokens.Status.success)
                    .accessibilityHidden(true)
            }
        }
    }

    private func refreshPermission() async {
        await followUps.refreshNotificationPermission()
        if followUps.notificationPermission != .notRequested { permissionError = nil }
    }

    private func requestPermission() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        permissionError = nil
        defer { isRequestingPermission = false }
        await followUps.requestNotificationPermission()
        if followUps.notificationPermission == .notRequested {
            permissionError = followUps.errorMessage ?? "Couldn't request notification permission. Try again."
        }
    }
}
