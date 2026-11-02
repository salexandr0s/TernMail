import AppKit
import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct ComposeIdentityTests {
    @Test(arguments: [false, true])
    func anExplicitSignatureChoiceWinsOverAPendingSenderDefault(custom: Bool) async throws {
        let (mailbox, cache, _, _) = try await fixture()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        let primary = try #require(model.senderChoices.first { $0.identity.isPrimary })
        // Closing a blank new message deliberately discards it. Keep a real
        // draft so closing must persist the explicit signature choice.
        model.content.subject = "Signature choice"
        model.selectSender(primary)
        // Do not yield: the sender's asynchronous default is still queued.
        if custom { model.replaceSignature(with: ComposeDocument(plainText: "Only this message")) }
        else { model.chooseSignature(nil) }
        let expected = model.content.signatureHTML
        await model.requestClose()
        let stored = try #require(try await cache.read { try $0.localDraft(id: id) })
        #expect(model.phase == .closed && stored.state == .editing)
        #expect(stored.fromAddress == primary.address)
        #expect(stored.signatureHTML == expected)
        #expect(custom ? stored.signatureHTML?.contains("Only this message") == true : stored.signatureHTML == nil)
        await mailbox.stop()
    }

    @Test func newMessagesUseTheDefaultAliasAndSenderChangesSaveTheirSignatureSnapshot() async throws {
        let (mailbox, cache, accounts, account) = try await fixture()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        #expect(model.fromEmail == "alias@example.com")
        #expect(model.content.signatureHTML == "<p>Alias signature</p>")
        #expect(try await cache.read { try $0.localDraft(id: id) }?.signatureHTML == "<p>Alias signature</p>")
        #expect(model.senderChoices.count == 2)
        let primary = try #require(model.senderChoices.first { $0.identity.isPrimary })
        model.selectSender(primary)
        model.content.subject = "Draft"
        try await waitUntil { !model.hasPendingEdits }
        let stored = try #require(try await cache.read { try $0.localDraft(id: id) })
        #expect(stored.fromAddress == account.email)
        #expect(stored.signatureHTML == "<p>Primary signature</p>")
        model.windowClosed()

        // A later Gmail signature change must not rewrite a saved draft.
        try await accounts.setSignature("<p>Changed elsewhere</p>", address: account.email, accountID: account.id)
        let reopened = ComposeModel(localDraftID: id, mailbox: mailbox)
        reopened.start()
        try await waitUntil { reopened.phase == .open }
        #expect(reopened.content.signatureHTML == "<p>Primary signature</p>")
        reopened.windowClosed()
        await mailbox.stop()
    }

    @Test func repliesUseTheOriginalToOrCcAliasAndRespectReplySignaturePreference() async throws {
        let (mailbox, cache, accounts, account) = try await fixture()
        let original = MessageRecord(
            accountID: account.id, id: "original", threadID: "thread", historyID: 1, date: .now, snippet: "",
            sender: "pat@example.com", recipients: "someone@example.com", cc: "ALIAS@EXAMPLE.COM", subject: "Meeting", sizeEstimate: 1
        )
        try await cache.write { tx in
            _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: original, labelIDs: [SystemLabel.inbox])])
            try tx.insertLocalDraft(LocalDraft(
                id: "reply", accountID: account.id, kind: .reply,
                content: DraftContent(to: [EmailAddress(address: "pat@example.com")]),
                rfcMessageID: "<reply@example.com>", sourceMessageID: original.id, now: .now
            ))
        }
        let model = ComposeModel(localDraftID: "reply", mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        #expect(model.fromEmail == "alias@example.com")
        #expect(model.content.signatureHTML == nil)
        #expect(!model.canChangeAccount)
        model.windowClosed()

        try await accounts.updateAccount(id: account.id) { $0.signatureOnReplies = true }
        try await cache.write { tx in
            try tx.insertLocalDraft(LocalDraft(
                id: "reply-signed", accountID: account.id, kind: .reply,
                rfcMessageID: "<reply-signed@example.com>", sourceMessageID: original.id, now: .now
            ))
        }
        let signed = ComposeModel(localDraftID: "reply-signed", mailbox: mailbox)
        signed.start()
        try await waitUntil { signed.phase == .open }
        #expect(signed.content.signatureHTML == "<p>Alias signature</p>")
        signed.windowClosed()
        await mailbox.stop()
    }

    @Test func anUntouchedSignedMessageStillDiscardsOnClose() async throws {
        let (mailbox, cache, _, _) = try await fixture()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        #expect(model.content.signatureHTML != nil)
        model.windowClosed()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) }) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) } == nil)
        await mailbox.stop()
    }

    @Test func directoryDenialStopsLaterSearchesUntilRelaunch() async throws {
        let (mailbox, accounts, transport) = try await directoryFixture(status: 403)
        #expect(await mailbox.directorySuggestions(for: "pa", accounts: accounts, excluding: []).isEmpty)
        #expect(await mailbox.directorySuggestions(for: "pat", accounts: accounts, excluding: []).isEmpty)
        #expect(await transport.calls == 1)
        await mailbox.stop()
    }

    @Test func returningToThePreviousCompletionQueryCancelsTheIntermediateRequest() async throws {
        let recipient = RecipientField(
            label: "To", addresses: .constant([]), requestsFocus: .constant(false), isEditable: true
        ) { query in
            if query == "beta" { try? await Task.sleep(for: .milliseconds(80)) }
            return [EmailAddress(address: "\(query)@example.com")]
        }
        let coordinator = recipient.makeCoordinator()
        let field = NSTokenField()
        func completions(_ query: String) -> [String] {
            coordinator.tokenField(field, completionsForSubstring: query, indexOfToken: 0, indexOfSelectedItem: nil) as? [String] ?? []
        }
        #expect(completions("alpha").isEmpty)
        try await waitUntil { completions("alpha") == ["alpha@example.com"] }
        #expect(completions("beta").isEmpty)
        // Reusing Alpha here would leave Beta alive and able to replace it later.
        #expect(completions("alpha").isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        #expect(completions("alpha") == ["alpha@example.com"])
    }

    @Test func directoryResultsAreDiscardedWhenPermissionChangesDuringTheRequest() async throws {
        let (mailbox, accounts, transport) = try await directoryFixture(status: 200, revokeDuringResponse: true)
        #expect(await mailbox.directorySuggestions(for: "pa", accounts: accounts, excluding: []).isEmpty)
        #expect(await transport.calls == 1)
        // Contacts can remain on even when a new grant omits the optional directory scope.
        #expect(await mailbox.directorySuggestions(for: "pat", accounts: accounts, excluding: []).isEmpty)
        #expect(await transport.calls == 1)
        await mailbox.stop()
    }

    private func directoryFixture(status: Int, revokeDuringResponse: Bool = false) async throws
        -> (AccountMailbox, AccountStore, ComposeDirectoryTransport) {
        let accounts = try AccountStore.inMemory()
        let account = AccountRecord(
            id: "directory", email: "me@example.com", displayName: nil,
            grantedScopes: GoogleScopes.base + GoogleScopes.required(for: .contacts) + [GoogleScopes.directory],
            addedAt: .now, hostedDomain: "example.com", enabledFeatures: [AccountFeature.contacts.rawValue]
        )
        try await accounts.save(account)
        let transport = ComposeDirectoryTransport(status: status, accounts: revokeDuringResponse ? accounts : nil)
        let mailbox = AccountMailbox(
            account: account, cache: try MailCache.inMemory(),
            gmail: GmailClient(tokens: ComposeDirectoryTokens(), transport: transport),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), snoozeStore: accounts
        )
        return (mailbox, accounts, transport)
    }

    private func fixture() async throws -> (MailboxModel, MailCache, AccountStore, AccountRecord) {
        let cache = try MailCache.inMemory()
        let accounts = try AccountStore.inMemory()
        let account = AccountRecord(id: "a", email: "me@example.com", displayName: "Me", grantedScopes: [], addedAt: .now)
        try await accounts.save(account)
        let identities = try JSONDecoder().decode([SendAsIdentity].self, from: Data(#"""
            [{"sendAsEmail":"me@example.com","isPrimary":true,"signature":"<p>Primary signature</p>"},
             {"sendAsEmail":"alias@example.com","isDefault":true,"verificationStatus":"accepted","signature":"<p>Alias signature</p>"},
             {"sendAsEmail":"pending@example.com","verificationStatus":"pending"}]
            """#.utf8))
        try await accounts.replaceIdentities(identities, accountID: account.id, fetchedAt: .now)
        let mailbox = MailboxModel(
            account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), snoozeStore: accounts
        )
        return (mailbox, cache, accounts, account)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

private struct ComposeDirectoryTokens: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "fixture-token" }
}

private actor ComposeDirectoryTransport: HTTPTransport {
    let status: Int
    let accounts: AccountStore?
    private(set) var calls = 0

    init(status: Int, accounts: AccountStore?) {
        self.status = status
        self.accounts = accounts
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        if let accounts {
            try await accounts.updateAccount(id: "directory") { account in
                account.grantedScopes.removeAll { $0 == GoogleScopes.directory }
            }
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        let body = status == 403 ? #"{"error":{"code":403}}"# : #"{"people":[{"resourceName":"people/1","names":[{"displayName":"Pat"}],"emailAddresses":[{"value":"pat@example.com"}]}]}"#
        return (Data(body.utf8), response)
    }
}
