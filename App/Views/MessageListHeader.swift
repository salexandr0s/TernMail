import MailStore
import SwiftUI

struct MessageListHeader: View {
    let mailbox: MailboxModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                TernPageHeader(title: mailbox.selectedLabelTitle, subtitle: scopeDescription)
                if mailbox.search.isActive {
                    Text(mailbox.searchResultsSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Tokens.Workspace.pageGutter)
            .padding(.vertical, Tokens.Space.s5)
            .auditLayoutBounds("mail.list.heading")

            if showsControlBand {
                Divider()
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    if mailbox.search.isActive, mailbox.selectedSavedSearch == nil {
                        SearchScopeBar(mailbox: mailbox)
                    }
                    if mailbox.listPreferences.presentsQuickFilters || showsDestructiveHeader {
                        actionHeader
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s3)
                .background(Tokens.Surface.muted)
            }

            SearchSuggestionsView(mailbox: mailbox)
            Divider()
        }
        .background(Tokens.Surface.primary)
        .auditLayoutBounds("mail.list.header")
    }

    private var scopeDescription: String {
        let accounts = mailbox.searchedAccounts.filter {
            !mailbox.search.isActive || mailbox.search.accountID == nil || $0.account.id == mailbox.search.accountID
        }
        let accountScope = accounts.count == 1
            ? accounts.first.map { mailbox.accountTitle($0.account) } ?? ""
            : "\(accounts.count.formatted()) accounts"
        guard mailbox.search.isActive, mailbox.selectedSavedSearch == nil else { return accountScope }
        let scope = mailbox.searchMailboxScope
        let mailboxScope = scope?.restriction == mailbox.search.restriction ? scope?.title ?? "All Mail" : "All Mail"
        return "\(mailboxScope) · \(accountScope)"
    }

    private var showsControlBand: Bool {
        (mailbox.search.isActive && mailbox.selectedSavedSearch == nil)
            || mailbox.listPreferences.presentsQuickFilters || showsDestructiveHeader
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
                            .help("Clear quick filters")
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
        // Search scope stays reachable when the list is too narrow for one row.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s2) {
                mailboxScope
                accountScope
                saveButton
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                mailboxScope
                HStack(spacing: Tokens.Space.s2) {
                    accountScope
                    Spacer(minLength: 0)
                    saveButton
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .popover(isPresented: $isSaving, attachmentAnchor: .point(.bottomTrailing), arrowEdge: .bottom) {
            SavedSearchEditor(mailbox: mailbox, existing: nil)
        }
    }

    @ViewBuilder private var mailboxScope: some View {
        let search = mailbox.search
        if let scope = mailbox.searchMailboxScope {
            Picker("Mailbox", selection: Binding(get: { search.restriction }, set: { search.restrict(to: $0) })) {
                Text("All Mail").tag(String?.none)
                Text(scope.title).tag(String?.some(scope.restriction))
            }
            .pickerStyle(.segmented)
        } else {
            Text("All Mail").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accountScope: some View {
        let search = mailbox.search
        let accounts = mailbox.searchAccountChoices
        if !accounts.isEmpty {
            Picker("Account", selection: Binding(get: { search.accountID }, set: { search.restrict(toAccount: $0) })) {
                Text("All Accounts").tag(String?.none)
                ForEach(accounts, id: \.id) { Text(mailbox.accountTitle($0)).tag(String?.some($0.id)) }
            }
            .pickerStyle(.menu)
            .lineLimit(1)
            .layoutPriority(1)
        }
    }

    private var saveButton: some View {
        Button("Save") { isSaving = true }
            .help("New Saved Search")
            .accessibilityLabel("New Saved Search")
            .accessibilityInputLabels([Text("Save"), Text("New Saved Search")])
            .fixedSize()
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
