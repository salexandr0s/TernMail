import GmailAPI
import SwiftUI

struct FiltersPane: View {
    @Bindable var model: SettingsModel
    let header: GmailSettingsHeader
    @State private var editor: FilterEditorSelection?
    @State private var deleting: GmailFilter?

    var body: some View {
        SettingsPage {
            header
            Section {
                if model.filters.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text("No filters")
                            Text("Choose which messages to match and what happens when they arrive.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(model.filters.enumerated()), id: \.offset) { _, filter in
                        filterRow(filter)
                    }
                }
            } header: {
                Text(model.filters.isEmpty ? "Filters" : "\(model.filters.count) \(model.filters.count == 1 ? "filter" : "filters")")
            } footer: {
                Text("Filters apply to new mail as it arrives.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsFooter {
                HStack(spacing: Tokens.Space.s2) {
                    if model.filters.count >= 1_000 {
                        Text("Gmail allows up to 1,000 filters.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Add Filter…", systemImage: "plus") { editor = FilterEditorSelection(filter: nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEdit || model.filters.count >= 1_000)
                }
            }
        }
        .sheet(item: $editor) { selection in
            FilterEditorSheet(model: model, original: selection.filter)
        }
        .ternConfirm("Delete this filter?", item: $deleting, actionTitle: "Delete Filter",
                     message: "Existing messages stay as they are. You can undo this change.") { filter in
            Task { await model.deleteFilter(filter) }
        }
    }

    private func filterRow(_ filter: GmailFilter) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(summary(filter))
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(actions(filter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if filter.id == nil {
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Tokens.Space.s2) {
                Button("Edit…") { editor = FilterEditorSelection(filter: filter) }
                    .accessibilityLabel("Edit filter: \(summary(filter))")
                Button("Delete…", role: .destructive) { deleting = filter }
                    .accessibilityLabel("Delete filter: \(summary(filter))")
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
        }
        .padding(.vertical, Tokens.Space.s1)
    }

    private func summary(_ filter: GmailFilter) -> String {
        let c = filter.criteria
        var parts: [String] = []
        if let value = c.from, !value.isEmpty { parts.append("From: \(value)") }
        if let value = c.to, !value.isEmpty { parts.append("To: \(value)") }
        if let value = c.subject, !value.isEmpty { parts.append("Subject: \(value)") }
        if let value = c.query, !value.isEmpty { parts.append(value) }
        if let value = c.negatedQuery, !value.isEmpty { parts.append("Excluding: \(value)") }
        if c.hasAttachment == true { parts.append("Has attachment") }
        if c.excludeChats == true { parts.append("Excludes chats") }
        if let size = c.size { parts.append("Size \(c.sizeComparison == .smaller ? "under" : "over") \(size) bytes") }
        return parts.isEmpty ? "All matching mail" : parts.joined(separator: " · ")
    }

    private func actions(_ filter: GmailFilter) -> String {
        let adds = (filter.action.addLabelIds ?? []).map { id in
            "Add \(model.labels.first(where: { $0.id == id })?.title ?? id)"
        }
        let removes = (filter.action.removeLabelIds ?? []).map { id in
            "Remove \(model.labels.first(where: { $0.id == id })?.title ?? id)"
        }
        let forward = filter.action.forward.map { ["Forward to \($0)"] } ?? []
        return (adds + removes + forward).joined(separator: " · ")
    }
}

private struct FilterEditorSelection: Identifiable {
    let id = UUID()
    let filter: GmailFilter?
}
