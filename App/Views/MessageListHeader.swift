import MailStore
import SwiftUI

struct MessageListHeader: View {
    let mailbox: MailboxModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mailbox.listPreferences.showsQuickFilters || showsDestructiveHeader {
                actionHeader
                    .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
            }
            SearchSuggestionsView(mailbox: mailbox)
        }
        .background(.bar)
    }

    private var showsDestructiveHeader: Bool {
        !mailbox.search.isActive && [SystemLabel.spam, SystemLabel.trash].contains(mailbox.selectedLabelID ?? "")
    }

    private var actionHeader: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if mailbox.listPreferences.showsQuickFilters {
                ScrollView(.horizontal) {
                    HStack(spacing: Tokens.Space.s1) {
                        ForEach(MailQuickFilter.allCases) { filter in
                            Toggle(isOn: Bindable(mailbox.listPreferences).filters.contains(filter)) {
                                Label(filter.title, systemImage: filter.symbol)
                            }
                                .toggleStyle(.button).controlSize(.small).help(filter.title)
                        }
                        if !mailbox.listPreferences.filters.isEmpty {
                            Button("Clear") { mailbox.listPreferences.filters = [] }.controlSize(.small)
                        }
                    }
                }
            }
            if showsDestructiveHeader {
                HStack {
                    Text("\(mailbox.currentMailboxMessageCount) messages").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(mailbox.selectedLabelID == SystemLabel.trash ? "Empty Trash…" : "Delete All Spam…") {
                        Task { await mailbox.triage.preparePermanentDeletion(entireMailbox: true) }
                    }
                    .controlSize(.small).disabled(mailbox.triage.isPreparing)
                }
            }
        }
    }
}

struct SearchSuggestionsView: View {
    let mailbox: MailboxModel
    @State private var suggestions: [MailSearchSuggestion] = []
    var body: some View {
        Group {
            if mailbox.search.isActive, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    ForEach(suggestions.prefix(4)) { suggestion in
                        Button {
                            mailbox.search.update(suggestion.query)
                            if suggestion.query.hasSuffix(":") { mailbox.search.focusField() }
                            else { mailbox.search.submit() }
                            suggestions = []
                        } label: {
                            Label(suggestion.title, systemImage: suggestion.symbol).font(.caption).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
                .accessibilityLabel("Search suggestions")
            }
        }
        .task(id: mailbox.search.text + mailbox.presentedAccounts.map(\.account.id).joined(separator: ":")) {
            suggestions = await mailbox.searchSuggestions(for: mailbox.search.text)
        }
    }
}
