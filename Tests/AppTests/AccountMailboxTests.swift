import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@MainActor
@Suite struct AccountMailboxTests {
    @Test func pausedMailboxRetainsLocalDraftWritesWithoutStartingNetworkWork() async throws {
        let account = AccountRecord(id: "paused", email: "me@example.invalid", displayName: nil,
            grantedScopes: GoogleScopes.base, addedAt: .now)
        let accounts = try AccountStore.inMemory()
        try await accounts.save(account)
        let cache = try MailCache.inMemory()
        let transport = MailboxIntegrationTransport()
        let mailbox = AccountMailbox(account: account, cache: cache,
            gmail: GmailClient(tokens: MailboxIntegrationTokens(), transport: transport),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            snoozeStore: accounts, syncEnabled: false)
        await mailbox.start()
        mailbox.syncNow()
        mailbox.checkSnoozes()
        let draft = LocalDraft(accountID: account.id, kind: .new, content: DraftContent(subject: "Local draft"),
            rfcMessageID: "<paused-draft@example.invalid>", now: .now)
        try await mailbox.engine.createDraft(draft)
        try await mailbox.engine.saveDraft(draft.id)
        await mailbox.stop()
        #expect(await transport.requests.isEmpty)
        let stored = try await cache.read { try $0.localDraft(id: draft.id) }
        #expect(stored?.content.subject == "Local draft")
        #expect(try await cache.read { try $0.pendingActions(accountID: account.id).isEmpty } == false)
    }

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
        #expect(connection?.fields == PeopleClient.Source.connections.syncSignature)
        #expect(other?.fields == PeopleClient.Source.otherContacts.syncSignature)
        let groups = try await cache.contactGroupSuggestions(accountID: account.id, matching: "Team")
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.accountID == account.id)
        #expect(group.resourceName == "contactGroups/team")
        #expect(group.name == "Team")
        #expect(group.memberCount == 2)
        #expect(group.isComplete)

        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests.map { $0.url?.host } == [
            "gmail.googleapis.com", "people.googleapis.com", "people.googleapis.com", "people.googleapis.com"
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer mailbox-test-token" })
        let groupRequest = try #require(requests.last)
        let groupURL = try #require(groupRequest.url)
        #expect(groupURL.path == "/v1/contactGroups")
        #expect(groupRequest.httpMethod == "GET")
        let groupQuery = try #require(URLComponents(url: groupURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(groupQuery.contains(URLQueryItem(name: "groupFields", value: "name,groupType,memberCount,metadata")))
        #expect(groupQuery.contains(URLQueryItem(name: "pageSize", value: "100")))

        try await accounts.updateAccount(id: account.id) { $0.enabledFeatures = [] }
        try await mailbox.engine.syncContacts()
        #expect(await transport.requests.count == 4)
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
        case ("people.googleapis.com", "/v1/contactGroups"):
            body = #"{"contactGroups":[{"resourceName":"contactGroups/team","name":"Team","groupType":"USER_CONTACT_GROUP","memberCount":2},{"resourceName":"contactGroups/myContacts","name":"Team System","groupType":"SYSTEM_CONTACT_GROUP","memberCount":3}]}"#
        default:
            throw URLError(.unsupportedURL)
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
