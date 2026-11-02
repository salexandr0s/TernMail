import AppKit
import MailStore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsDestination.storageKey) private var storedDestination = SettingsDestination.general.rawValue
    @State private var search = ""
    @State private var unsaved = SettingsUnsavedChanges()
    @State private var pendingLeave: PendingLeave?

    init() {
        // Before the window first reads the stored pane.
        SettingsDestination.migrateSavedPane()
    }

    private var destination: SettingsDestination { SettingsDestination.stored(storedDestination) }

    /// The sidebar follows the stored pane, so another window can land Settings
    /// on a pane by writing the key before it opens Settings.
    private var selection: Binding<SettingsDestination?> {
        Binding(destination, set: { leave(for: .destination($0 ?? .general)) })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SettingsSearchField(text: $search) { selectSearchResult() }
                    .frame(height: Tokens.Settings.rowHeight)
                    .padding(Tokens.Space.s3)
                Divider()
                sidebar
            }
            .frame(width: Tokens.Settings.sidebarWidth)
            .background(SidebarMaterial())
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let subtitle = destination.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Tokens.Space.s5)
                        .padding(.top, Tokens.Space.s3)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: Tokens.Settings.contentWidth + Tokens.Space.s4 * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Tokens.Surface.muted)
            .navigationTitle(destination.title)
            .navigationSubtitle(sectionTitle)
        }
        .frame(minWidth: Tokens.Settings.minWidth, idealWidth: Tokens.Settings.width,
               minHeight: Tokens.Settings.minHeight, idealHeight: Tokens.Settings.height)
        .environment(unsaved)
        .background {
            WindowCloseGuard { window in
                guard unsaved.subject != nil else { return true }
                pendingLeave = .close(window)
                return false
            }
        }
        .ternConfirm(
            "Discard changes to the \(unsaved.subject ?? "pane")?",
            item: $pendingLeave,
            actionTitle: "Discard Changes",
            message: "Your unsaved edits will be lost."
        ) { leave in
            unsaved.clear()
            switch leave {
            case .destination(let destination): storedDestination = destination.rawValue
            case .close(let window): window.close()
            }
        }
    }

    /// Where the window title alone would be ambiguous, the section names the area.
    private var sectionTitle: String {
        guard let section = SettingsNavigationSection.section(containing: destination),
              section.title != destination.title else { return "" }
        return section.title
    }

    private func leave(for leave: PendingLeave) {
        if case .destination(let next) = leave, next == destination { return }
        guard unsaved.subject == nil else { pendingLeave = leave; return }
        if case .destination(let next) = leave { storedDestination = next.rawValue }
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(SettingsNavigationSection.sections) { section in
                let destinations = section.destinations.filter { $0.matches(search) }
                if !destinations.isEmpty {
                    if section.title.isEmpty {
                        Section { rows(destinations) }
                    } else {
                        Section {
                            rows(destinations)
                        } header: {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            if !SettingsDestination.allCases.contains(where: { $0.matches(search) }) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("No matching settings").font(.callout.weight(.medium))
                    Text("Try a category or a word like \"notifications\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, Tokens.Space.s2)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Tokens.Settings.rowHeight)
        .accessibilityLabel("Settings categories")
    }

    private func rows(_ destinations: [SettingsDestination]) -> some View {
        ForEach(destinations) { item in
            Label {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
            } icon: {
                Image(systemName: item.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: Tokens.Settings.navigationIcon, height: Tokens.Settings.navigationIcon)
                    .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    .accessibilityHidden(true)
            }
            .tag(item)
            .padding(.vertical, Tokens.Space.s0_5)
        }
    }

    private func selectSearchResult() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let first = SettingsNavigationSection.sections
            .flatMap(\.destinations).first(where: { $0.matches(search) }) {
            leave(for: .destination(first))
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
            Button("Open Connections") { leave(for: .destination(.connections)) }
                .buttonStyle(.borderedProminent)
        }
    }

    /// What the user asked to do while a pane still holds unsaved edits.
    private enum PendingLeave {
        case destination(SettingsDestination)
        case close(NSWindow)
    }
}

private struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search settings"
        field.setAccessibilityLabel("Search settings")
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField
        init(_ parent: SettingsSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}
