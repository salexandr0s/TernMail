import MailStore
import SwiftUI

struct MessageListHeader: View {
    let mailbox: MailboxModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSearchScope {
                SearchScopeBar(mailbox: mailbox)
                    .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
                    .ternTransition(.disclosure)
            }
            if mailbox.listPreferences.presentsQuickFilters || showsDestructiveHeader {
                actionHeader
                    .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
                    .ternTransition(.disclosure)
            }
            SearchSuggestionsView(mailbox: mailbox)
        }
        .background(.bar)
        .ternAnimation(value: showsSearchScope)
        .ternAnimation(value: mailbox.listPreferences.presentsQuickFilters)
        .ternAnimation(value: showsDestructiveHeader)
    }

    private var showsSearchScope: Bool {
        mailbox.search.isActive && mailbox.selectedSavedSearch == nil
    }

    private var showsDestructiveHeader: Bool {
        !mailbox.search.isActive && [SystemLabel.spam, SystemLabel.trash].contains(mailbox.selectedLabelID ?? "")
    }

    private var actionHeader: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if mailbox.listPreferences.presentsQuickFilters {
                HStack(spacing: Tokens.Space.s2) {
                    ViewThatFits(in: .horizontal) {
                        quickFilters.labelStyle(.titleAndIcon).fixedSize()
                        quickFilters.labelStyle(.iconOnly).fixedSize()
                    }
                    Spacer(minLength: 0)
                    if !mailbox.listPreferences.filters.isEmpty {
                        Button("Clear") { mailbox.listPreferences.filters = [] }
                            .controlSize(.small)
                            .fixedSize()
                            .ternTransition(.fade)
                    }
                }
                .ternTransition(.disclosure)
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
                .ternTransition(.disclosure)
            }
        }
        .ternAnimation(value: mailbox.listPreferences.filters.isEmpty, duration: Tokens.Motion.fast)
    }

    private var quickFilters: some View {
        HStack(spacing: Tokens.Space.s1) {
            ForEach(MailQuickFilter.allCases) { filter in
                Toggle(isOn: Bindable(mailbox.listPreferences).filters.contains(filter)) {
                    Label(filter.title, systemImage: filter.symbol)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(filter.title)
                .accessibilityLabel(filter.title)
            }
        }
    }
}

/// Where the results come from: all mail or the selected mailbox, and every
/// account in view or one of them. The search can be saved from here too.
private struct SearchScopeBar: View {
    let mailbox: MailboxModel
    @State private var isSaving = false

    var body: some View {
        // In a narrow list the account menu truncates its title.
        ViewThatFits(in: .horizontal) {
            controls(narrow: false)
            controls(narrow: true)
        }
        .labelsHidden()
        .controlSize(.small)
        .popover(isPresented: $isSaving, attachmentAnchor: .point(.bottomTrailing), arrowEdge: .bottom) {
            SavedSearchEditor(mailbox: mailbox, existing: nil)
        }
    }

    private func controls(narrow: Bool) -> some View {
        let search = mailbox.search
        let accounts = mailbox.searchAccountChoices
        return HStack(spacing: Tokens.Space.s1) {
            if let scope = mailbox.searchMailboxScope {
                Picker("Mailbox", selection: Binding(get: { search.restriction }, set: { search.restrict(to: $0) })) {
                    Text("All Mail").tag(String?.none)
                    Text(scope.title).tag(String?.some(scope.restriction))
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } else {
                Text("All Mail").font(.callout).foregroundStyle(.secondary)
            }
            if !accounts.isEmpty {
                Picker("Account", selection: Binding(get: { search.accountID }, set: { search.restrict(toAccount: $0) })) {
                    Text("All Accounts").tag(String?.none)
                    ForEach(accounts, id: \.id) { Text(mailbox.accountTitle($0)).tag(String?.some($0.id)) }
                }
                .pickerStyle(.menu)
                .fixedSize(horizontal: !narrow, vertical: false)
                .layoutPriority(1)
            }
            Button("Save") { isSaving = true }
                .help("New Saved Search")
                .accessibilityLabel("New Saved Search")
                // Voice Control users say the name they see.
                .accessibilityInputLabels([Text("Save"), Text("New Saved Search")])
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                .ternTransition(.disclosure)
            }
        }
        .ternAnimation(value: mailbox.search.isActive && !suggestions.isEmpty)
        .task(id: mailbox.search.text + mailbox.presentedAccounts.map(\.account.id).joined(separator: ":")) {
            suggestions = await mailbox.searchSuggestions(for: mailbox.search.text)
        }
    }
}
