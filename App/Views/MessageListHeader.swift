import GmailAPI
import MailStore
import MessageContent
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
                            Toggle(isOn: Binding(
                                get: { mailbox.listPreferences.filters.contains(filter) },
                                set: { value in
                                    if value { mailbox.listPreferences.filters.insert(filter) }
                                    else { mailbox.listPreferences.filters.remove(filter) }
                                }
                            )) { Label(filter.title, systemImage: filter.symbol) }
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

struct MailSearchSuggestion: Identifiable, Equatable {
    let title: String
    let query: String
    let symbol: String
    var id: String { query }
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

extension MailboxModel {
    var currentMailboxMessageCount: Int {
        selectedAccounts.reduce(0) { total, owner in
            let label = owner.labels.first { $0.id == selectedLabelID }
            return total + (label?.messagesTotal ?? label?.threadsTotal ?? listEntries.filter { $0.message.accountID == owner.account.id }.count)
        }
    }

    func performSwipe(_ action: MailSwipeAction, on row: MailListRowID) {
        switch action {
        case .archive: performListAction(.archive, rows: [row])
        case .trash: performListAction(.trash, rows: [row])
        case .read: toggleListRead([row])
        case .star: toggleListStar([row])
        case .move: showMoveTo(forRows: [row])
        case .label: showEditLabels(forRows: [row])
        case .spam: triage.perform(.spam, targets: actionTargets(forRows: [row]))
        case .snooze:
            showSnoozeDate(forRows: [row])
        case .none: break
        }
    }

    func searchSuggestions(for text: String) async -> [MailSearchSuggestion] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 200 else { return [] }
        let query = text.lowercased()
        var result: [MailSearchSuggestion] = []
        let operators = ["has:attachment", "is:unread", "is:starred", "is:important", "from:", "to:", "label:", "before:", "after:"]
        for value in operators where value.hasPrefix(query) && value != query {
            result.append(.init(title: value, query: value, symbol: "magnifyingglass"))
        }
        for owner in presentedAccounts {
            for label in owner.labels where label.name.lowercased().contains(query) && !label.isSystem {
                let escaped = label.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                result.append(.init(title: label.name, query: "label:\"\(escaped)\"", symbol: "tag"))
            }
            let account = try? await accountStore?.accounts().first { $0.id == owner.account.id }
            let includeContacts = account.map { $0.enabledFeatures.contains(AccountFeature.contacts.rawValue) && GoogleScopes.isCovered(.contacts, by: $0.grantedScopes) } ?? false
            var addresses = (try? await cache.recipientSuggestions(accountID: owner.account.id, matching: text, includeContacts: includeContacts, limit: 3)) ?? []
            guard !Task.isCancelled else { return [] }
            if includeContacts {
                let latest = try? await accountStore?.accounts().first { $0.id == owner.account.id }
                if latest?.enabledFeatures.contains(AccountFeature.contacts.rawValue) != true
                    || latest.map({ GoogleScopes.isCovered(.contacts, by: $0.grantedScopes) }) != true {
                    addresses = (try? await cache.recipientSuggestions(accountID: owner.account.id, matching: text, includeContacts: false, limit: 3)) ?? []
                }
            }
            for address in addresses {
                let escaped = address.address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                result.append(.init(title: address.displayString, query: "from:\"\(escaped)\"", symbol: "person"))
            }
        }
        var seen = Set<String>()
        return Array(result.filter { seen.insert($0.query).inserted && $0.query != text }.prefix(8))
    }
}
