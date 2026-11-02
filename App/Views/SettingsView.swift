import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var destination: SettingsDestination
    @State private var search = ""
    @State private var unsaved = SettingsUnsavedChanges()
    private let navigationRequests = SettingsNavigationRequests.shared

    init() {
        // Before the window first reads the stored pane.
        SettingsDestination.migrateSavedPane()
        _destination = State(initialValue: SettingsDestination.stored(
            UserDefaults.standard.string(forKey: SettingsDestination.storageKey) ?? ""))
    }

    /// Intercept navigation before SwiftUI replaces an explicit-save editor.
    private var selection: Binding<SettingsDestination?> {
        Binding(destination, set: { leave(for: $0 ?? .general) })
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection, search: $search, onSubmit: selectSearchResult)
                .frame(width: Tokens.Settings.sidebarWidth)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Tokens.Surface.canvas)
        }
        .navigationTitle("Settings")
        .navigationSubtitle(destination.title)
        .frame(minWidth: Tokens.Settings.minWidth, idealWidth: Tokens.Settings.width,
               minHeight: Tokens.Settings.minHeight, idealHeight: Tokens.Settings.height)
        .environment(unsaved)
        .background {
            WindowCloseGuard { window in
                guard unsaved.subject != nil else { return true }
                unsaved.request { window.close() }
                return false
            }
        }
        .ternConfirm(
            "Discard changes to the \(unsaved.pendingChange?.subject ?? "pane")?",
            item: Bindable(unsaved).pendingChange,
            actionTitle: "Discard Changes",
            message: "Your unsaved edits will be lost."
        ) { change in unsaved.discardAndApply(change) }
        .onChange(of: navigationRequests.revision, initial: true) { _, _ in
            if let requested = navigationRequests.takeRequest() {
                leave(for: requested)
            }
        }
        .onChange(of: destination) { _, destination in
            UserDefaults.standard.set(destination.rawValue, forKey: SettingsDestination.storageKey)
        }
    }

    private var contentWidth: CGFloat {
        (destination.usesWideLayout ? Tokens.Layout.readableWidth : Tokens.Settings.contentWidth)
            + Tokens.Space.s4 * 2
    }

    private var pageHeader: some View {
        TernPageHeader(title: destination.title, subtitle: destination.subtitle) {
            if unsaved.subject != nil {
                Label("Unsaved changes", systemImage: "pencil.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.unsavedChanges")
            }
        }
        .padding(.horizontal, Tokens.Workspace.pageGutter)
        .padding(.vertical, Tokens.Space.s5)
        .background(Tokens.Surface.muted)
        .accessibilityIdentifier("settings.pageHeader")
    }

    private func leave(for next: SettingsDestination) {
        guard next != destination else { return }
        unsaved.request { destination = next }
    }

    private func selectSearchResult() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let first = SettingsNavigationSection.sections
            .flatMap(\.destinations).first(where: { $0.matches(search) }) {
            leave(for: first)
        }
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .general: GeneralSettings()
        case .mailActions: TriagePreferencesPane()
        case .notifications:
            if let model = app.accountPreferences, let notifications = app.mailNotifications {
                NotificationSettingsView(preferences: model, notifications: notifications)
            } else { unavailable }
        case .connections: AccountsSettings()
        case .accountPreferences:
            if let model = app.accountPreferences { AccountPreferencesView(model: model) }
            else { unavailable }
        case .profiles:
            if let model = app.accountPreferences { ProfilesView(model: model) }
            else { unavailable }
        case .reading: ReadingSettingsView()
        case .messageList: MessageListSettingsView(mailbox: app.mailbox)
        case .attachments: AttachmentPreferencesView()
        case .writing, .templates, .suggestions: ComposeSettingsPane(destination: destination)
        case .signatures: SignaturesSettingsPane()
        case .organizeMail: MailOrganizationView()
        case .filters: IntegrationSettingsView(pane: .filters)
        case .blocked: IntegrationSettingsView(pane: .blocked)
        case .vacation: IntegrationSettingsView(pane: .vacation)
        case .calendar: CalendarManagementView(model: app.calendar)
        case .assistant: AssistantSettingsView(model: app.assistant)
        case .failedChanges: FailedChangesView()
        case .maintenance: MaintenanceSettingsView(app: app)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Add a Google account to set up its preferences, profiles and notifications.")
        } actions: {
            Button("Open Connections") { leave(for: .connections) }
                .buttonStyle(.borderedProminent)
        }
    }
}
