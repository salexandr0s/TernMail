import Foundation
import GmailAPI
import MailStore

struct MailSearchSuggestion: Identifiable, Equatable {
    let title: String
    let query: String
    let symbol: String
    var id: String { query }
}

extension MailboxModel {
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
