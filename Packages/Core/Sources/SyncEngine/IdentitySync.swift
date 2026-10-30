import Foundation
import GmailAPI
import MailStore

/// The send-as list an identity refresh reads. `GmailClient` adopts it.
public protocol IdentityService: Sendable {
    func sendAsIdentities() async throws -> [SendAsIdentity]
}

extension GmailClient: IdentityService {}

extension SyncEngine {
    /// Replaces the account's stored identities with Gmail's send-as list,
    /// unless they were fetched less than `maxAge` seconds ago. Does nothing
    /// without a config store.
    public func refreshIdentities(olderThan maxAge: TimeInterval = 0) async throws {
        guard let identities, let accounts else { return }
        let accountID = accountID
        if maxAge > 0 {
            let stored = try await accounts.identities(accountID: accountID)
            if let fetchedAt = stored.map(\.fetchedAt).min(), now().timeIntervalSince(fetchedAt) < maxAge { return }
        }
        let list = try await identities.sendAsIdentities()
        // Gmail always lists the primary address, so an empty list is a bad
        // answer and mustn't clear the stored identities.
        guard !list.isEmpty else { throw GmailError.decoding("sendAs") }
        let fetchedAt = now()
        try await gated { try await accounts.replaceIdentities(list, accountID: accountID, fetchedAt: fetchedAt) }
    }
}
