import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@MainActor
@Suite struct AccountMailboxTests {
    @Test func identityAndContactSyncUseTheAccountStoreAndGmailSession() async throws {
        let account = AccountRecord(
            id: "a", email: "me@example.invalid", displayName: "Me",
            grantedScopes: GoogleScopes.base + GoogleScopes.required(for: .contacts), addedAt: .now
        )
        let accounts = try AccountStore.inMemory()
        try await accounts.save(account)
        let cache = try MailCache.inMemory()
        let transport = MailboxIntegrationTransport()
        let mailbox = AccountMailbox(
            account: account, cache: cache,
            gmail: GmailClient(tokens: MailboxIntegrationTokens(), transport: transport),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            snoozeStore: accounts
        )

        try await mailbox.engine.refreshIdentities()
        let identity = try #require(try await accounts.identities(accountID: account.id).first)
        #expect(identity.address == account.email)
        #expect(identity.signatureHTML == "<p>Regards</p>")
        #expect(identity.isPrimary)

        // Contacts start off. Enabling them after the mailbox was created
        // must use the current config, not its initial AccountRecord.
        try await mailbox.engine.syncContacts()
        #expect(await transport.requests.count == 1)
        try await accounts.updateAccount(id: account.id) { $0.enabledFeatures = [AccountFeature.contacts.rawValue] }
        try await mailbox.engine.syncContacts()
        let connection = try await cache.read { try $0.contactSync(source: .connection, accountID: account.id) }
        let other = try await cache.read { try $0.contactSync(source: .other, accountID: account.id) }
        #expect(connection?.syncToken == "saved-contacts")
        #expect(other?.syncToken == "other-contacts")
        #expect(connection?.fields == PeopleClient.fields)
        #expect(other?.fields == PeopleClient.fields)

        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.map { $0.url?.host } == [
            "gmail.googleapis.com", "people.googleapis.com", "people.googleapis.com"
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer mailbox-test-token" })

        try await accounts.updateAccount(id: account.id) { $0.enabledFeatures = [] }
        try await mailbox.engine.syncContacts()
        #expect(await transport.requests.count == 3)
        await mailbox.stop()
    }
}

private struct MailboxIntegrationTokens: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "mailbox-test-token" }
}

private actor MailboxIntegrationTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let body: String
        switch (url.host, url.path) {
        case ("gmail.googleapis.com", "/gmail/v1/users/me/settings/sendAs"):
            body = #"{"sendAs":[{"sendAsEmail":"me@example.invalid","isPrimary":true,"signature":"<p>Regards</p>"}]}"#
        case ("people.googleapis.com", "/v1/people/me/connections"):
            body = #"{"connections":[],"nextSyncToken":"saved-contacts"}"#
        case ("people.googleapis.com", "/v1/otherContacts"):
            body = #"{"otherContacts":[],"nextSyncToken":"other-contacts"}"#
        default:
            throw URLError(.unsupportedURL)
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
