import MailStore
import SwiftUI

struct MeetingPreparationSourcePicker: View {
    @Bindable var model: MeetingPreparationModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var pendingSources: Set<String> = []
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            PopupHeader(title: "Include a conversation", systemImage: "envelope.badge",
                subtitle: "Search cached mail in your current profile.")
            HStack(spacing: Tokens.Space.s2) {
                TextField("Search conversations", text: $model.sourceSearchText)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .onSubmit(search)
                    .accessibilityIdentifier("meeting-source-search")
                Button("Search", action: search)
                    .disabled(model.isSearching || model.sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("meeting-source-search-submit")
            }
            .padding(.horizontal, Tokens.Space.s5).padding(.bottom, Tokens.Space.s3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    if model.isSearching { ProgressView("Searching conversations…").controlSize(.small) }
                    if let error = model.searchError ?? actionError {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Tokens.Status.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.searchResults.isEmpty && !model.isSearching {
                        Text(model.sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Search by subject or distinctive words from the conversation."
                            : "No conversations to show. Try another search.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.searchResults) { source in
                        let saved = model.sources.first { $0.key == source.key }
                        let isIncluded = saved?.isExplicitlyIncluded == true && saved?.isExcluded == false
                        MeetingPreparationSourceRowView(source: saved ?? source,
                            accountName: model.followUps.accountName(for: source.key.accountID),
                            actionTitle: saved?.isExcluded == true ? "Restore" : isIncluded ? "Included" : "Include",
                            actionSymbol: isIncluded ? "checkmark.circle" : "plus.circle",
                            open: { model.openConversation(source.key) },
                            act: {
                                guard !isIncluded, pendingSources.insert(source.id).inserted else { return }
                                actionError = nil
                                Task {
                                    if saved?.isExcluded == true { await model.restore(source.key) }
                                    else { await model.include(source.key) }
                                    pendingSources.remove(source.id)
                                    if model.sources.first(where: { $0.key == source.key })?.isExcluded != false {
                                        actionError = model.errorMessage ?? "Couldn’t include this conversation. Try again."
                                    }
                                }
                            }, isActionDisabled: isIncluded || pendingSources.contains(source.id))
                    }
                }
                .padding(.horizontal, Tokens.Space.s5).padding(.bottom, Tokens.Space.s4)
            }
            .frame(minHeight: Tokens.Layout.editorMinHeight, maxHeight: Tokens.Settings.editorMaxContentHeight)
            PopupFooter {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("meeting-source-picker-done")
            }
        }
        .frame(width: Tokens.Settings.editorWidth)
        .background(Tokens.Surface.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-source-picker")
        .task { searchFocused = true }
    }

    private func search() {
        guard !model.isSearching, !model.sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await model.searchSources() }
    }
}
