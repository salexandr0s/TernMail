import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct OwnAddressTests {
    @Test func anIdentityRefreshMarksMailToEachAddressTheAccountSendsAs() async throws {
        let cache = try MailCache.inMemory()
        let identities = Identities(list: try decode([SendAsIdentity].self, #"""
            [{"sendAsEmail":"me@example.com","isPrimary":true},
             {"sendAsEmail":"alias@example.com","verificationStatus":"accepted"},
             {"sendAsEmail":"pending@example.com","verificationStatus":"pending"}]
            """#))
        let accounts = try AccountStore.inMemory()
        try await accounts.save(AccountRecord(id: account, email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: baseDate))
        let engine = SyncEngine(
            accountID: account, sender: EmailAddress(address: "Me@Example.com"),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernTests-\(UUID().uuidString)"),
            gmail: FakeGmail(), identities: identities, accounts: accounts, cache: cache,
            sendsAutomatically: false
        )
        try await cache.write { tx in
            _ = try tx.upsertMessages([
                incoming("direct", to: "me@example.com"),
                incoming("alias", to: "Alias <alias@example.com>"),
                incoming("pending", to: "pending@example.com"),
            ])
        }
        #expect(try await marked(cache, among: ["direct", "alias", "pending"]) == [])

        try await engine.refreshIdentities()
        // A send-as address Gmail hasn't verified isn't the account's.
        #expect(try await marked(cache, among: ["direct", "alias", "pending"]) == ["direct", "alias"])
    }
}

private struct Identities: IdentityService {
    let list: [SendAsIdentity]
    func sendAsIdentities() async throws -> [SendAsIdentity] { list }
}

private func marked(_ cache: MailCache, among ids: [String]) async throws -> Set<String> {
    try await cache.read { tx in
        Set(try ids.filter { try tx.message(id: $0, accountID: account)?.addressedToMe == true })
    }
}

private func incoming(_ id: String, to recipients: String) -> CacheTransaction.MessageUpdate {
    CacheTransaction.MessageUpdate(
        record: MessageRecord(
            accountID: account, id: id, threadID: id, historyID: 100, date: baseDate,
            snippet: "", sender: "pat@example.com", recipients: recipients, cc: nil, subject: "Subject", sizeEstimate: 1
        ),
        labelIDs: [SystemLabel.inbox]
    )
}
