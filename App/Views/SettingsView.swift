import AppKit
import MailStore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: SettingsDestination? = .general
    @State private var search = ""

    private var destination: SettingsDestination { selection ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SettingsSearchField(text: $search) { selectSearchResult() }
                    .frame(height: Tokens.Settings.rowHeight)
                    .padding(Tokens.Space.s3)
                sidebar
            }
            .frame(width: Tokens.Settings.sidebarWidth)
            .background(SettingsSidebarMaterial())
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(destination.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.top, Tokens.Space.s3)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: Tokens.Settings.contentWidth + Tokens.Space.s4 * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(colorScheme == .dark ? Color(nsColor: .textBackgroundColor) : Tokens.Surface.canvas)
            .navigationTitle(destination.title)
        }
        .frame(minWidth: Tokens.Settings.minWidth, idealWidth: Tokens.Settings.width,
               minHeight: Tokens.Settings.minHeight, idealHeight: Tokens.Settings.height)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(SettingsNavigationSection.sections) { section in
                let destinations = section.destinations.filter { $0.matches(search) }
                if !destinations.isEmpty {
                    Section {
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
                    } header: {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
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

    private func selectSearchResult() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let first = SettingsNavigationSection.sections
            .flatMap(\.destinations).first(where: { $0.matches(search) }) {
            selection = first
        }
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .general: GeneralPreferencesPane()
        case .accounts: AccountSettingsPane()
        case .profiles:
            if let model = app.accountPreferences { ProfilesView(model: model) }
            else { unavailable }
        case .notifications:
            if let model = app.accountPreferences, let notifications = app.mailNotifications {
                NotificationSettingsView(preferences: model, notifications: notifications)
            } else { unavailable }
        case .reading: ReadingSettingsView()
        case .messageList: MessageListSettingsView(mailbox: app.mailbox)
        case .composing: ComposeSettingsPane()
        case .signatures: IntegrationSettingsView(pane: .signatures)
        case .filters: IntegrationSettingsView(pane: .filters)
        case .blocked: IntegrationSettingsView(pane: .blocked)
        case .vacation: IntegrationSettingsView(pane: .vacation)
        case .attachments: AttachmentPreferencesView()
        case .failedChanges: FailedChangesView()
        case .maintenance: MaintenanceSettingsView(app: app)
        case .assistant: AssistantSettingsView(model: app.assistant, showsIntroduction: false)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Add an account to get started", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Your accounts, profiles, and notifications will appear here.")
        } actions: {
            Button("Open Accounts") { selection = .accounts }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// AppKit supplies the sidebar material and respects Reduce Transparency.
private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
