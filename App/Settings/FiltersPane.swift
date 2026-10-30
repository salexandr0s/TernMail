import GmailAPI
import SwiftUI

struct FiltersPane: View {
    @Bindable var model: SettingsModel
    @State private var editor: FilterEditorSelection?
    @State private var deleting: GmailFilter?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                Text("Filters apply to new mail as it arrives.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Filter", systemImage: "plus") { editor = FilterEditorSelection(filter: nil) }
                    .disabled(!model.canEdit || model.filters.count >= 1_000)
            }
            if model.filters.isEmpty {
                ContentUnavailableView("No filters", systemImage: "line.3.horizontal.decrease.circle", description: Text("Create a filter to organize new messages."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        ForEach(Array(model.filters.enumerated()), id: \.offset) { _, filter in
                            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                                HStack(alignment: .top) {
                                    Text(summary(filter)).font(.body.weight(.medium)).textSelection(.enabled)
                                    Spacer()
                                    if filter.id == nil { Text("Saving…").font(.caption).foregroundStyle(.secondary) }
                                    Button("Edit") { editor = FilterEditorSelection(filter: filter) }
                                        .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                                    Button("Delete", role: .destructive) { deleting = filter }
                                        .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                                }
                                Text(actions(filter)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(Tokens.Space.s3)
                            .ternSurface()
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
