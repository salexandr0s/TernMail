import Foundation
import GmailAPI
import MailStore
@testable import MessageContent
import Testing
@testable import SyncEngine

@Suite struct ComposeFeatureTests {
    @Test func archiveIntentWaitsForDeliveryAndUndoClearsIt() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        try await seed(cache, [("original", "t", [SystemLabel.inbox])])
        let draft = LocalDraft(accountID: account, kind: .reply,
                               content: DraftContent(to: [.init(address: "pat@example.com")], archiveAfterSend: true),
                               rfcMessageID: "<reply@example.com>", threadID: "t", now: baseDate)
        try await engine.createDraft(draft)
        try await engine.sendDraft(draft.id, delay: 10)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.allSatisfy { $0.kind == .sendDraft })
        #expect(try await engine.undoSend(draft.id))
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.archiveAfterSend } == false)
        var content = try #require(try await cache.read { try $0.localDraft(id: draft.id)?.content })
        content.archiveAfterSend = true
        try await engine.sendDraft(draft.id, content: content, delay: 0)
        await engine.sendDueDrafts()
        let actions = try await cache.read { try $0.pendingActions(accountID: account) }
        #expect(actions.count == 1)
        #expect(actions.first?.kind == .modifyThreads)
        #expect(actions.first?.threadIDs == ["t"])
        #expect(actions.first?.removeLabelIDs == [SystemLabel.inbox])
    }

    @Test func aRejectedSendNeverQueuesArchive() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = LocalDraft(accountID: account, kind: .reply,
                               content: DraftContent(to: [.init(address: "pat@example.com")], archiveAfterSend: true),
                               rfcMessageID: "<reply@example.com>", threadID: "t", now: baseDate)
        try await engine.createDraft(draft)
        await gmail.failNextDraftCall("send", with: .http(status: 400, reason: "invalidArgument"))
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.state } == .editing)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.allSatisfy { $0.kind != .modifyThreads })
    }

    @Test func inlineCIDFontAndSignaturePlacementSurviveSavedRevisions() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = LocalDraft(accountID: account, kind: .reply,
                               content: DraftContent(body: ComposeDocument(plainText: "Body"), signatureHTML: "<p>Signed</p>",
                                                     composeFont: .fixedWidth, signatureAboveQuote: false, signatureSeparator: true),
                               rfcMessageID: "<inline@example.com>", quotedHTML: "<blockquote>Quote</blockquote>", quotedPlainText: "Quote", now: baseDate)
        try await engine.createDraft(draft)
        let attachment = try #require(try await engine.attachData(Data([1, 2, 3]), filename: "image.png", mimeType: "image/png", to: draft.id))
        let inline = try #require(try await engine.markInlineImage(attachment))
        let cid = try #require(inline.contentID)
        var content = draft.content
        content.body.blocks.append(.init(runs: [.init("", image: InlineImageReference(contentID: cid, altText: "Image"))]))
        try await engine.saveDraft(draft.id, content: content)
        await engine.sendDueDrafts()
        let raw = try #require(await gmail.uploads.last).raw
        let parsed = MIMEReader.parse(raw)
        func leaves(_ part: MIMEEntity) -> [MIMEEntity] { part.parts.isEmpty ? [part] : part.parts.flatMap(leaves) }
        let parts = leaves(parsed)
        #expect(parts.contains { $0.header("Content-ID") == "<\(cid)>" })
        let html = try #require(parts.first { $0.mimeType == "text/html" }?.text)
        #expect(html.contains("font-family:Menlo"))
        let quotePosition = try #require(html.range(of: "Quote")?.lowerBound)
        let signaturePosition = try #require(html.range(of: "Signed")?.lowerBound)
        #expect(quotePosition < signaturePosition)
        let plain = try #require(parts.first { $0.mimeType == "text/plain" }?.text)
        #expect(plain.replacingOccurrences(of: "\r\n", with: "\n").contains("-- \nSigned"))
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.content } == content)
        #expect(try await engine.markInlineImage(inline)?.contentID == cid)
    }

    @Test func sendAgainCopiesRecipientsBodyAndAllAttachmentBytes() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let html = Data("<p>Body<img src=\"cid:image@tern.local\" alt=\"Diagram\"></p>".utf8).base64EncodedString()
        let file = Data("Agenda".utf8).base64EncodedString()
        let json = #"""
            {"id":"sent","threadId":"source","labelIds":["SENT"],"payload":{"mimeType":"multipart/mixed",
            "headers":[{"name":"To","value":"pat@example.com"},{"name":"Cc","value":"team@example.com"},{"name":"Subject","value":"Plan"}],
            "parts":[{"partId":"0","mimeType":"text/html","body":{"data":"\#(html)"}},
            {"partId":"1","mimeType":"image/png","filename":"image.png","headers":[{"name":"Content-ID","value":"<image@tern.local>"},{"name":"Content-Disposition","value":"inline"}],"body":{"data":"AQID"}},
            {"partId":"2","mimeType":"text/plain","filename":"agenda.txt","headers":[{"name":"Content-ID","value":"<unreferenced-file@example.com>"}],"body":{"data":"\#(file)"}}]}}
            """#
        await gmail.add(try decode(GmailMessage.self, json))
        let copied = try await engine.startAgain(messageID: "sent")
        let stored = try #require(try await cache.read { try $0.localDraft(id: copied.draft.id) })
        #expect(stored.to.map(\.address) == ["pat@example.com"])
        #expect(stored.cc.map(\.address) == ["team@example.com"])
        #expect(stored.subject == "Plan" && stored.threadID == nil && stored.inReplyTo == nil)
        #expect(stored.body.blocks.flatMap(\.runs).contains { $0.image?.contentID == "image@tern.local" })
        let attachments = try await cache.read { try $0.outgoingAttachments(localDraftID: copied.draft.id) }
        #expect(attachments.count == 2)
        #expect(attachments.first { $0.filename == "agenda.txt" }?.contentID == nil)
        #expect(try await engine.outgoingAttachmentData(#require(attachments.first { $0.filename == "agenda.txt" })) == Data("Agenda".utf8))
        try await engine.saveDraft(stored.id)
        await engine.sendDueDrafts()
        #expect(String(decoding: try #require(await gmail.uploads.last).raw, as: UTF8.self).contains("filename=\"agenda.txt\""))
    }

    @Test func replyAllExcludesEveryVerifiedOwnAlias() async throws {
        let cache = try MailCache.inMemory()
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: account, email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: baseDate))
        try await store.replaceIdentities(try decode([SendAsIdentity].self, #"[{"sendAsEmail":"alias@example.com","verificationStatus":"accepted"}]"#),
                                          accountID: account, fetchedAt: baseDate)
        let gmail = FakeGmail()
        await gmail.add(try decode(GmailMessage.self, #"""
            {"id":"received","threadId":"t","payload":{"mimeType":"text/plain","body":{"data":"SGk"},
            "headers":[{"name":"From","value":"pat@example.com"},{"name":"To","value":"ALIAS@example.com, team@example.com"},
            {"name":"Cc","value":"me@example.com"},{"name":"Message-ID","value":"<received@example.com>"}]}}
            """#))
        let engine = SyncEngine(accountID: account, sender: .init(address: "me@example.com"),
                                outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                                gmail: gmail, accounts: store, cache: cache, sendsAutomatically: false)
        let draft = try await engine.startReply(.replyAll, to: "received")
        let recipients = Set((draft.to + draft.cc).map(\.normalized))
        #expect(recipients == ["pat@example.com", "team@example.com"])
    }

    @Test func aCachedReplyRetainsInlineImagesWithoutFetchingTheOriginalAgain() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await cache.write { tx in
            _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                accountID: account, id: "cached", threadID: "t", historyID: 1, date: baseDate, snippet: "",
                sender: "pat@example.com", recipients: "me@example.com", cc: nil, subject: "Image", sizeEstimate: 1,
                rfcMessageID: "<cached@example.com>"
            ), labelIDs: [SystemLabel.inbox])])
            try tx.saveBodies([MessageBodyRecord(accountID: account, messageID: "cached", html: "<p>Original<img src=\"cid:cached-image@tern.local\"></p>", plainText: "Original", fetchedAt: baseDate)])
            try tx.replaceMIMEResources([MIMEInlineResourceRecord(accountID: account, messageID: "cached", contentID: "cached-image@tern.local",
                                                                partID: "1", mimeType: "image/png", data: Data([1, 2, 3]))], messageID: "cached", accountID: account)
        }
        let draft = try await engine.startReply(.reply, to: "cached")
        let copied = try await cache.read { try $0.outgoingAttachments(localDraftID: draft.id) }
        #expect(copied.count == 1 && copied.first?.contentID == "cached-image@tern.local")
        #expect(await gmail.metadataRequests.isEmpty)
        try await engine.saveDraft(draft.id)
        await engine.sendDueDrafts()
        #expect(String(decoding: try #require(await gmail.uploads.last).raw, as: UTF8.self).contains("Content-ID: <cached-image@tern.local>"))
    }

    @Test func outgoingInlineAPIsRejectForgedRowsFromAnotherAccount() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let own = try await engine.startMessage()
        let foreign = LocalDraft(accountID: "other", kind: .new, rfcMessageID: "<other@example.com>", now: baseDate)
        let row = try await cache.write { tx in
            try tx.insertLocalDraft(foreign)
            return try tx.addOutgoingAttachment(OutgoingAttachment(localDraftID: foreign.id, filename: "other.png", mimeType: "image/png",
                                                                  size: 3, path: "other/file.png"), now: baseDate)
        }
        var forged = try #require(row)
        forged.localDraftID = own.id
        let forgedCopy = forged
        await #expect(throws: GmailError.self) { try await engine.markInlineImage(forgedCopy) }
        await #expect(throws: GmailError.self) { try await engine.outgoingAttachmentData(forgedCopy) }
        #expect(try await cache.read { try $0.outgoingAttachments(localDraftID: foreign.id).first?.contentID } == nil)
    }
}
