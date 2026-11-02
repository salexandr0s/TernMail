import AppKit
import SwiftUI

/// Native selection stays connected to the Settings window's unsaved-edit guard.
struct SettingsSidebar: View {
    @Binding var selection: SettingsDestination?
    @Binding var search: String
    let onSubmit: () -> Void

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                    Text("Tern").font(.caption).foregroundStyle(.secondary)
                    Text("Settings").font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                }
                SettingsSearchField(text: $search, onSubmit: onSubmit)
                    .frame(height: Tokens.Settings.rowHeight)
            }
            .padding(Tokens.Space.s4)

            List(selection: $selection) {
                ForEach(SettingsNavigationSection.sections) { section in
                    let matches = section.destinations.filter { $0.matches(search) }
                    if !matches.isEmpty {
                        Section {
                            ForEach(matches) { destination in
                                row(destination).tag(destination)
                            }
                        } header: {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                if !SettingsDestination.allCases.contains(where: { $0.matches(search) }) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Text("No matching settings").font(.callout.weight(.medium))
                        Text("Try a word like “notifications” or “signature”.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Tokens.Space.s3)
                    .accessibilityElement(children: .combine)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Tokens.Settings.rowHeight)
            .accessibilityLabel("Settings categories")
        }
        .background(SidebarMaterial())
    }

    private func row(_ destination: SettingsDestination) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(destination.title)
                    .font(.body)
                    .lineLimit(2)
                if isSearching {
                    Text(destination.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        } icon: {
            Image(systemName: destination.symbol)
                .font(.body)
                .frame(width: Tokens.Settings.navigationIcon, height: Tokens.Settings.navigationIcon)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Tokens.Space.s1)
        .help(destination.subtitle)
        .accessibilityHint(destination.subtitle)
        .accessibilityIdentifier("settings.destination.\(destination.rawValue)")
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
