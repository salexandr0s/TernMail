import MailStore
import SwiftUI

/// Native sidebar navigation keeps every Settings pane reachable by keyboard.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: SettingsDestination? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsNavigationSection.sections) { section in
                    Section(section.title) {
                        ForEach(section.destinations) { destination in
                            Label(destination.title, systemImage: destination.symbol).tag(destination)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Settings categories")
            .navigationSplitViewColumnWidth(min: Tokens.Layout.sidebarMinWidth,
                ideal: Tokens.Layout.sidebarWidth, max: Tokens.Layout.sidebarMaxWidth)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle((selection ?? .general).title)
                .background(Tokens.Surface.canvas)
        }
        .frame(width: Tokens.Calendar.settingsWidth, height: Tokens.Calendar.settingsHeight)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general: GeneralPreferencesPane()
        case .accounts: AccountSettingsPane()
        case .profiles:
            if let model = app.accountPreferences { ProfilesView(model: model) }
            else { unavailable }
        case .notifications:
            if let model = app.accountPreferences, let notifications = app.mailNotifications {
                NotificationSettingsView(preferences: model, notifications: notifications)
            } else { unavailable }
        case .reading:
            Form { ReadingSettingsView() }.formStyle(.grouped)
        case .messageList: MessageListSettingsView(mailbox: app.mailbox)
        case .composing: ComposeSettingsPane()
        case .signatures: IntegrationSettingsView(pane: .signatures)
        case .filters: IntegrationSettingsView(pane: .filters)
        case .blocked: IntegrationSettingsView(pane: .blocked)
        case .vacation: IntegrationSettingsView(pane: .vacation)
        case .attachments: AttachmentPreferencesView()
        case .failedChanges: FailedChangesView()
        case .maintenance: MaintenanceSettingsView(app: app)
        case .assistant: AssistantSettingsView(model: app.assistant)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Settings unavailable", systemImage: "person.crop.circle",
            description: Text("Open the mailbox and add an account to use these settings."))
    }
}
