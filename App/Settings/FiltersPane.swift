import GmailAPI
import SwiftUI

struct FiltersPane: View {
    @Bindable var model: SettingsModel
    @State private var editor: FilterEditorSelection?
    @State private var deleting: GmailFilter?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("\(model.filters.count) \(model.filters.count == 1 ? "filter" : "filters")")
                        .font(.body.weight(.medium))
                    Text("Applies to new mail as it arrives.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Filter", systemImage: "plus") { editor = FilterEditorSelection(filter: nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canEdit || model.filters.count >= 1_000)
            }
            if model.filters.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("No filters").font(.body.weight(.medium))
                    Text("Create a filter to choose which messages to match and what happens when they arrive.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        ForEach(Array(model.filters.enumerated()), id: \.offset) { _, filter in
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
                                    Button("Edit") { editor = FilterEditorSelection(filter: filter) }
                                        .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                                    Button("Delete", role: .destructive) { deleting = filter }
                                        .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                                }
                                .controlSize(.small)
                                .fixedSize()
                            }
                            .padding(Tokens.Space.s3)
                            .settingsSurface()
                        }
                    }
                }
            }
        }
        .sheet(item: $editor) { selection in
            FilterEditorSheet(model: model, original: selection.filter)
        }
        .confirmationDialog("Delete this filter?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Filter", role: .destructive) {
                if let deleting { Task { await model.deleteFilter(deleting) } }
                deleting = nil
            }
        } message: { Text("Existing messages stay as they are. You can undo this change.") }
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
            "Add \(model.labels.first(where: { $0.id == id })?.name ?? id)"
        }
        let removes = (filter.action.removeLabelIds ?? []).map { id in
            "Remove \(model.labels.first(where: { $0.id == id })?.name ?? id)"
        }
        let forward = filter.action.forward.map { ["Forward to \($0)"] } ?? []
        return (adds + removes + forward).joined(separator: " · ")
    }
}

private struct FilterEditorSelection: Identifiable {
    let id = UUID()
    let filter: GmailFilter?
}
