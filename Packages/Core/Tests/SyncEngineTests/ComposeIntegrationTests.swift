import Foundation
import GmailAPI
import MailStore
import Testing
@testable import MessageContent
@testable import SyncEngine

@Suite struct ComposeIntegrationTests {
    @Test func savesAndSendsTheSelectedIdentityWithTheDraftsSignature() async throws {
        let (engine, cache, gmail, _, accounts) = try await makeIntegrationEngine()
        let draft = integrationDraft(from: " ALIAS@example.COM ", signature: "<p>Saved signature</p>")
        try await engine.createDraft(draft)
        try await accounts.setSignature("<p>Changed identity signature</p>", address: "alias@example.com", accountID: account)

        try await engine.saveDraft(draft.id)
        await engine.sendDueDrafts()
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        let uploads = await gmail.uploads
        #expect(uploads.count == 2)
        for upload in uploads {
            let message = MIMEReader.parse(upload.raw)
            #expect(EmailAddress.parseList(message.header("From") ?? "") == [EmailAddress(name: "Alias Sender", address: "Alias@Example.com")])
            #expect(EmailAddress.parseList(message.header("Reply-To") ?? "") == [EmailAddress(address: "alias-replies@example.com")])
            let parts = leaves(message)
            let plain = try #require(parts.first { $0.mimeType == "text/plain" }?.text)
            let html = try #require(parts.first { $0.mimeType == "text/html" }?.text)
            try expectOrder(["Written body", "Saved signature", "Quoted original"], in: plain)
            try expectOrder(["Written body", "Saved signature", "Quoted original"], in: html)
            #expect(!html.contains("Changed identity signature"))
        }
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
    }

    @Test func anUnselectedFromUsesThePrimaryAddressAndLegacyDraftsStillSend() async throws {
        let (engine, _, gmail, _, _) = try await makeIntegrationEngine()
        let draft = integrationDraft(from: nil)
        try await engine.createDraft(draft)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()
        let message = MIMEReader.parse(try #require(await gmail.uploads.last).raw)
        #expect(EmailAddress.parseList(message.header("From") ?? "") == [EmailAddress(name: "Primary Sender", address: "me@example.com")])
        #expect(EmailAddress.parseList(message.header("Reply-To") ?? "") == [EmailAddress(address: "primary-replies@example.com")])

        // Audit mode and older callers have no config store or selected identity.
        let (legacy, _, legacyGmail, _) = try await makeEngine()
        let older = integrationDraft(from: nil)
        try await legacy.createDraft(older)
        try await legacy.sendDraft(older.id, delay: 0)
        await legacy.sendDueDrafts()
        let olderMessage = MIMEReader.parse(try #require(await legacyGmail.uploads.last).raw)
        #expect(EmailAddress.parseList(olderMessage.header("From") ?? "") == [EmailAddress(name: "Me", address: "me@example.com")])
        #expect(olderMessage.header("Reply-To") == nil)
    }

    @Test(arguments: ["missing@example.com", "pending@example.com", "foreign@example.com"])
    func unavailableIdentitiesNeverUploadAsAnotherSender(address: String) async throws {
        let (engine, cache, gmail, _, accounts) = try await makeIntegrationEngine()
        try await accounts.save(AccountRecord(id: "other", email: "other@example.com", displayName: nil, grantedScopes: [], addedAt: baseDate))
        try await accounts.replaceIdentities(try decode([SendAsIdentity].self, #"[{"sendAsEmail":"foreign@example.com","verificationStatus":"accepted"}]"#), accountID: "other", fetchedAt: baseDate)
        let draft = integrationDraft(from: address)
        try await engine.createDraft(draft)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        #expect(await gmail.uploads.isEmpty)
        let stored = try #require(try await cache.read { try $0.localDraft(id: draft.id) })
        #expect(stored.state == .editing)
        #expect(stored.fromAddress == address)
        #expect(stored.sendError == ComposeError.senderUnavailable.errorDescription)
        #expect(try await cache.read { try $0.composeRows(localDraftID: draft.id) }.isEmpty)
    }

    @Test func anInvalidReplyToFailsBeforeUploading() async throws {
        let (engine, cache, gmail, _, accounts) = try await makeIntegrationEngine()
        try await accounts.replaceIdentities(try decode([SendAsIdentity].self, #"[{"sendAsEmail":"alias@example.com","verificationStatus":"accepted","replyToAddress":"not an address"}]"#), accountID: account, fetchedAt: baseDate)
        let draft = integrationDraft()
        try await engine.createDraft(draft)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        #expect(await gmail.uploads.isEmpty)
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.sendError } == ComposeError.invalidReplyTo.errorDescription)
    }

    @Test(arguments: ["missing", "malformed", "request"])
    func anInvitationReplyNeedsAValidReplyCalendar(kind: String) async throws {
        let (engine, cache, gmail, _, _) = try await makeIntegrationEngine()
        let calendar: String? = switch kind {
        case "missing": nil
        case "malformed": "BEGIN:VCALENDAR"
        default: requestCalendar
        }
        let draft = integrationDraft(kind: .invitationReply, calendar: calendar)
        try await engine.createDraft(draft)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        #expect(await gmail.uploads.isEmpty)
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.sendError } == ComposeError.invalidCalendar.errorDescription)
    }

    @Test func anUncertainReplySendIsReconciledAfterItsIdentityDisappears() async throws {
        let (engine, cache, gmail, clock, accounts) = try await makeIntegrationEngine()
        let calendar = try replyCalendar()
        let draft = integrationDraft(kind: .invitationReply, calendar: calendar)
        let answer = try await storeReply(draft, in: cache)
        await gmail.failNextDraftCall("send", with: .transport(.networkConnectionLost), afterApplying: true)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.sendRequested } == true)
        let message = MIMEReader.parse(try #require(await gmail.uploads.last).raw)
        #expect(EmailAddress.parseList(message.header("To") ?? "") == [EmailAddress(address: "organizer@example.com")])
        let calendarPart = try #require(leaves(message).first { $0.mimeType == "text/calendar" })
        #expect(MIMEReader.parameters(of: calendarPart.header("Content-Type") ?? "")["method"]?.uppercased() == "REPLY")
        #expect(calendarPart.body == Data(calendar.utf8))
        #expect(leaves(message).contains { $0.mimeType == "text/plain" && $0.text?.contains("Accepted: Planning") == true })

        try await accounts.replaceIdentities(try decode([SendAsIdentity].self, #"[{"sendAsEmail":"me@example.com","isPrimary":true}]"#), accountID: account, fetchedAt: baseDate)
        clock.advance(10)
        await engine.sendDueDrafts()

        #expect(await gmail.draftCalls == ["create", "send D1"])
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
        #expect(try await cache.read { try $0.composeRows(localDraftID: draft.id) }.isEmpty)
        #expect(try await cache.read { try $0.invitationReply(uid: "event", recurrenceKey: "", accountID: account) } == answer)
    }

    @Test func discardingARefusedReplyRemovesItsStoredAnswer() async throws {
        let (engine, cache, gmail, _, accounts) = try await makeIntegrationEngine()
        let draft = integrationDraft(kind: .invitationReply, calendar: try replyCalendar())
        let answer = try await storeReply(draft, in: cache)
        try await accounts.replaceIdentities(try decode([SendAsIdentity].self, #"[{"sendAsEmail":"me@example.com","isPrimary":true}]"#), accountID: account, fetchedAt: baseDate)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        let refused = try #require(try await cache.read { try $0.localDraft(id: draft.id) })
        #expect(refused.state == .editing)
        #expect(refused.sendError == ComposeError.senderUnavailable.errorDescription)
        #expect(try await cache.read { try $0.invitationReply(uid: "event", recurrenceKey: "", accountID: account) } == answer)

        #expect(try await engine.discardDraft(draft.id, hold: 0))
        await engine.sendDueDrafts()

        #expect(await gmail.uploads.isEmpty)
        #expect(await gmail.draftCalls.isEmpty)
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
        #expect(try await cache.read { try $0.invitationReply(uid: "event", recurrenceKey: "", accountID: account) } == nil)
        #expect(try await cache.read { try $0.composeRows(localDraftID: draft.id) }.isEmpty)
    }

    @Test(arguments: [false, true])
    func undoingAReplyCleansUpLocalAndPreviouslySavedDrafts(savedFirst: Bool) async throws {
        let (engine, cache, gmail, clock, _) = try await makeIntegrationEngine()
        let draft = integrationDraft(kind: .invitationReply, calendar: try replyCalendar())
        _ = try await storeReply(draft, in: cache)
        if savedFirst {
            try await engine.saveDraft(draft.id)
            await engine.sendDueDrafts()
        }
        try await engine.sendDraft(draft.id, delay: 10)

        #expect(try await engine.undoSend(draft.id))
        #expect(try await cache.read { try $0.invitationReply(uid: "event", recurrenceKey: "", accountID: account) } == nil)
        await engine.sendDueDrafts()
        clock.advance(20)
        await engine.sendDueDrafts()

        #expect(await gmail.draftCalls == (savedFirst ? ["create", "delete D1"] : []))
        #expect(await gmail.draftsByID.isEmpty)
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
        #expect(try await cache.read { try $0.composeRows(localDraftID: draft.id) }.isEmpty)
    }

    @Test func undoWaitsForAnInFlightSaveAndKeepsANewerAnswer() async throws {
        let (engine, cache, gmail, _, _) = try await makeIntegrationEngine()
        let draft = integrationDraft(kind: .invitationReply, calendar: try replyCalendar())
        _ = try await storeReply(draft, in: cache)
        try await engine.saveDraft(draft.id)
        await gmail.holdNextChange()
        let saving = Task { await engine.sendDueDrafts() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gmail.isHolding), ContinuousClock.now < deadline { await Task.yield() }
        let isHolding = await gmail.isHolding
        guard isHolding else {
            await gmail.release()
            _ = await saving.value
            Issue.record("The draft save did not reach the held request")
            return
        }
        do {
            try await engine.sendDraft(draft.id, delay: 10)
            let newer = InvitationReplyRecord(
                accountID: account, uid: "event", recurrenceKey: "", participationStatus: .declined,
                localDraftID: "newer-reply", queuedAt: baseDate.addingTimeInterval(1)
            )
            try await cache.write { try $0.saveInvitationReply(newer) }
            #expect(try await engine.undoSend(draft.id))
            // The discard shares the draft's queue key and cannot overtake its save.
            #expect(await engine.sendDueDrafts() == 0)
            await gmail.release()
            _ = await saving.value
            await engine.sendDueDrafts()

            #expect(await gmail.draftCalls == ["create", "delete D1"])
            #expect(await gmail.draftsByID.isEmpty)
            #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
            #expect(try await cache.read { try $0.invitationReply(uid: "event", recurrenceKey: "", accountID: account) } == newer)
        } catch {
            await gmail.release()
            _ = await saving.value
            throw error
        }
    }
}

private func makeIntegrationEngine() async throws -> (SyncEngine, MailCache, FakeGmail, TestClock, AccountStore) {
    let cache = try MailCache.inMemory()
    let gmail = FakeGmail()
    let clock = TestClock()
    let accounts = try AccountStore.inMemory()
    try await accounts.save(AccountRecord(id: account, email: "me@example.com", displayName: "Me", grantedScopes: [], addedAt: baseDate))
    let identities = try decode([SendAsIdentity].self, #"[{"sendAsEmail":"me@example.com","displayName":"Primary Sender","replyToAddress":"primary-replies@example.com","isPrimary":true},{"sendAsEmail":"Alias@Example.com","displayName":"Alias Sender","replyToAddress":"alias-replies@example.com","isDefault":true,"verificationStatus":"accepted"},{"sendAsEmail":"pending@example.com","verificationStatus":"pending"}]"#)
    try await accounts.replaceIdentities(identities, accountID: account, fetchedAt: baseDate)
    let engine = SyncEngine(
        accountID: account, sender: EmailAddress(name: "Me", address: "me@example.com"),
        outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernTests-\(UUID().uuidString)", directoryHint: .isDirectory),
        gmail: gmail, accounts: accounts, cache: cache, sendsAutomatically: false, now: clock.now
    )
    return (engine, cache, gmail, clock, accounts)
}

private func integrationDraft(
    from: String? = "alias@example.com", signature: String? = nil,
    kind: LocalDraft.Kind = .reply, calendar: String? = nil
) -> LocalDraft {
    let invitation = kind == .invitationReply
    return LocalDraft(
        id: "compose", accountID: account, kind: kind,
        content: DraftContent(
            to: [EmailAddress(address: invitation ? "organizer@example.com" : "recipient@example.com")],
            subject: invitation ? "Accepted: Planning" : "Re: Planning",
            body: ComposeDocument(plainText: invitation ? "Accepted: Planning" : "Written body"),
            fromAddress: from, signatureHTML: signature
        ),
        rfcMessageID: "<compose@example.com>",
        quotedHTML: invitation ? nil : "<blockquote>Quoted original</blockquote>",
        quotedPlainText: invitation ? nil : "Quoted original", calendarPart: calendar, now: baseDate
    )
}

private func storeReply(_ draft: LocalDraft, in cache: MailCache) async throws -> InvitationReplyRecord {
    let answer = InvitationReplyRecord(
        accountID: account, uid: "event", recurrenceKey: "", participationStatus: .accepted,
        localDraftID: draft.id, queuedAt: baseDate
    )
    try await cache.write { tx in
        try tx.insertLocalDraft(draft)
        try tx.saveInvitationReply(answer)
    }
    return answer
}

private let requestCalendar = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Tests//EN", "METHOD:REQUEST",
    "BEGIN:VEVENT", "UID:event", "SEQUENCE:3", "DTSTAMP:20261030T100000Z",
    "SUMMARY:Planning", "DTSTART:20261031T100000Z", "ORGANIZER:mailto:organizer@example.com",
    "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:alias@example.com", "END:VEVENT", "END:VCALENDAR",
].joined(separator: "\r\n") + "\r\n"

private func replyCalendar() throws -> String {
    let invitation = try Invitation(data: Data(requestCalendar.utf8))
    let attendee = try #require(invitation.attendee(matchingAnyOf: ["alias@example.com"]))
    return InvitationReply.calendar(replyingTo: invitation, as: attendee, answer: .accepted, now: baseDate)
}

private func leaves(_ entity: MIMEEntity) -> [MIMEEntity] {
    entity.parts.isEmpty ? [entity] : entity.parts.flatMap(leaves)
}

private func expectOrder(_ markers: [String], in text: String) throws {
    var remaining = text.startIndex..<text.endIndex
    for marker in markers {
        let range = try #require(text.range(of: marker, range: remaining))
        remaining = range.upperBound..<text.endIndex
    }
}
