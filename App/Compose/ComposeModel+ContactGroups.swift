import GmailAPI
import MailStore
import MessageContent

extension ComposeModel {
    func groupSuggestions(for text: String) async -> [ContactGroupSuggestion] {
        guard let owner, let store = mailbox.accountStore,
              let account = try? await store.accounts().first(where: { $0.id == owner.account.id }),
              AccountFeature.named(account.enabledFeatures).contains(.contacts),
              GoogleScopes.isCovered(.contacts, by: account.grantedScopes) else { return [] }
        let found = (try? await mailbox.cache.contactGroupSuggestions(accountID: account.id, matching: text)) ?? []
        guard !Task.isCancelled, draft?.accountID == account.id else { return [] }
        return found
    }

    func expandGroup(_ group: ContactGroupSuggestion) async -> [EmailAddress]? {
        guard isEditable, let owner, group.accountID == owner.account.id else { return nil }
        expandingGroups += 1
        defer { expandingGroups -= 1 }
        do {
            let result = try await owner.engine.expandContactGroup(group)
            guard !Task.isCancelled, isEditable, draft?.accountID == group.accountID else { return nil }
            guard result.isComplete else {
                alert = "Tern couldn't load every address in “\(group.name)”. No addresses were added."
                return nil
            }
            let blocked = (try? await mailbox.accountStore?.blockedSuggestionAddresses(accountID: group.accountID)) ?? []
            guard let current = try await mailbox.accountStore?.accounts().first(where: { $0.id == group.accountID }),
                  !Task.isCancelled, draft?.accountID == group.accountID, isEditable,
                  AccountFeature.named(current.enabledFeatures).contains(.contacts), GoogleScopes.isCovered(.contacts, by: current.grantedScopes)
            else { return nil }
            var excluded = Set<String>()
            for recipient in content.to { excluded.insert(recipient.normalized) }
            for recipient in content.cc { excluded.insert(recipient.normalized) }
            for recipient in content.bcc { excluded.insert(recipient.normalized) }
            excluded.formUnion(blocked)
            excluded.formUnion(senderChoices.filter { $0.account.id == group.accountID }.map { $0.identity.lowercasedAddress })
            return result.recipients.filter { !excluded.contains($0.normalized) }
        } catch {
            guard !Task.isCancelled else { return nil }
            alert = "Couldn't load “\(group.name)”. No addresses were added."
            return nil
        }
    }
}
