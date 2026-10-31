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
    /// unless they were fetched less than `maxAge` seconds ago, and gives the
    /// cache the addresses that mark mail addressed to the account. Without a
    /// config store nothing is fetched, and the sender's address is the only
    /// one.
    public func refreshIdentities(olderThan maxAge: TimeInterval = 0) async throws {
        // The stored identities first, so mail a pass stores before Gmail
        // answers is marked by the addresses known so far.
        try await updateOwnAddresses()
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
        try await updateOwnAddresses()
    }

    /// Gives the cache the account's own addresses: the sender's, and each
    /// stored identity Gmail lets the account send as.
    func updateOwnAddresses() async throws {
        let accountID = accountID
        let stored = try await accounts?.identities(accountID: accountID) ?? []
        let addresses = Set([sender.normalized] + stored.filter(\.canSend).map(\.lowercasedAddress))
        try await write { tx in try tx.setOwnAddresses(addresses, accountID: accountID) }
    }
}
