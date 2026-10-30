import Foundation
import GmailAPI
import MailStore
import MessageContent

extension AccountMailbox {
    /// Directory rows follow local suggestions and never replace their names or order.
    func directorySuggestions(for text: String, accounts: AccountStore?, excluding: Set<String>) async -> [EmailAddress] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !isDirectorySearchUnavailable, let people, let accounts,
              let current = try? await accounts.accounts().first(where: { $0.id == account.id }),
              current.allowsDirectorySuggestions
        else { return [] }
        do {
            let page = try await people.searchDirectory(query)
            guard !Task.isCancelled else { return [] }
            // Recheck permission after the response so a disconnected source cannot reappear.
            guard let latest = try await accounts.accounts().first(where: { $0.id == current.id }),
                  latest.allowsDirectorySuggestions else { return [] }
            var seen = excluding
            return page.people.filter { !$0.isDeleted }.flatMap { person in
                person.addresses.compactMap { address in
                    let email = EmailAddress(name: person.displayName, address: address)
                    guard email.isValid, seen.insert(email.normalized).inserted else { return nil }
                    return email
                }
            }
        } catch PeopleError.directoryUnavailable {
            isDirectorySearchUnavailable = true
        } catch GmailError.http(status: 403, _) {
            isDirectorySearchUnavailable = true
        } catch {}
        return []
    }
}

private extension AccountRecord {
    var allowsDirectorySuggestions: Bool {
        hostedDomain != nil && AccountFeature.named(enabledFeatures).contains(.contacts)
            && GoogleScopes.isCovered(.contacts, by: grantedScopes)
            && GoogleScopes.isCovered(GoogleScopes.directory, by: grantedScopes)
    }
}
