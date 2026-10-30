import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct AssistantMailTests {
    @Test func readsUncachedContentWithoutMarkingMailReadOrChangingTheCache() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("cached", "cached-thread", [SystemLabel.inbox, SystemLabel.unread])])
        let message = try assistantFixture(id: "uncached", thread: "new-thread", text: "Please review the proposal.")
        await gmail.setThread(try assistantThreadFixture([message], id: "new-thread"))

        let result = try await engine.assistantReadThread("new-thread")
        #expect(result.messages.first?.text == "Please review the proposal.")
        #expect(result.messages.first?.messageID == "uncached")
        #expect(result.truncated == false)
        #expect(try await cache.read { try $0.thread(id: "cached-thread", accountID: account) }?.isUnread == true)
        #expect(try await cache.read { try $0.thread(id: "new-thread", accountID: account) } == nil)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
        #expect(await gmail.changes.isEmpty)
        try await engine.assistantLoadSource("new-thread")
        #expect(try await cache.read { try $0.thread(id: "new-thread", accountID: account) }?.isUnread == true)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
    }

    @Test func reportsTruncatedTextAndMissingBodyParts() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        let long = try assistantFixture(id: "long", thread: "t", text: String(repeating: "a", count: 20_001))
        let missing = try assistantFixture(id: "missing", thread: "t", externalBody: "missing-part")
        await gmail.setThread(try assistantThreadFixture([long, missing], id: "t"))
        let result = try await engine.assistantReadThread("t")
        #expect(result.truncated)
        #expect(result.messages[0].text.count == 20_000)
        #expect(result.messages[1].limitations == ["A message body part could not be downloaded."])
    }

    @Test func stoppedEngineDoesNotReturnAResponseThatArrivedLate() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.setThread(try assistantThreadFixture([try assistantFixture(id: "m", thread: "t")], id: "t"))
        await gmail.holdNextThread()
        let read = Task { try await engine.assistantReadThread("t") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gmail.isHoldingThread), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gmail.isHoldingThread)
        await engine.stop()
        await gmail.releaseThread()
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test func attachmentLimitAndThreadOwnershipAreCheckedBeforeDownloading() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        let large = try assistantFixture(id: "m", thread: "t", attachmentSize: 5_000_001)
        await gmail.add(large)
        await #expect(throws: AssistantMailError.attachmentTooLarge) {
            try await engine.assistantReadAttachment(messageID: "m", partID: "1")
        }
        await #expect(throws: AssistantMailError.invalidTarget) {
            try await engine.assistantReadAttachment(messageID: "m", partID: "1", expectedThreadID: "another-thread")
        }
        #expect(await gmail.attachmentRequests.isEmpty)
    }

    @Test func replyDraftIsEditableThreadedAndIdempotentWithoutSending() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try assistantFixture(id: "m", thread: "t", text: "Can you review this?"))
        let draft = try await engine.assistantPrepareDraft(
            id: "reserved", replyKind: .reply, messageID: "m", expectedThreadID: "t", recipients: [],
            subject: "Ignored", text: "I will review it today.", isAuthorized: { true }
        )
        let again = try await engine.assistantPrepareDraft(
            id: "reserved", replyKind: .reply, messageID: "m", expectedThreadID: "t", recipients: [],
            subject: "Ignored", text: "I will review it today.", isAuthorized: { true }
        )
        #expect(draft.id == again.id)
        #expect(draft.state == .editing)
        #expect(draft.threadID == "t")
        #expect(draft.inReplyTo == "<m@example.invalid>")
        #expect(draft.to.first?.address == "sender@example.invalid")
        #expect(draft.body == ComposeDocument(plainText: "I will review it today."))
        #expect(try await cache.read { try $0.localDrafts(accountID: account) }.count == 1)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.map(\.kind) == [.saveDraft])
        #expect(await gmail.draftCalls.isEmpty)
    }

    @Test func revokedAuthorizationPreventsDraftCreation() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        await #expect(throws: AssistantMailError.accessChanged) {
            try await engine.assistantPrepareDraft(
                id: "denied", replyKind: nil, messageID: nil, expectedThreadID: nil,
                recipients: [EmailAddress(address: "recipient@example.invalid")], subject: "Proposal", text: "Draft",
                isAuthorized: { false }
            )
        }
        #expect(try await cache.read { try $0.localDrafts(accountID: account) }.isEmpty)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
    }
}

private func assistantFixture(id: String, thread: String, text: String = "Body", externalBody: String? = nil, attachmentSize: Int? = nil) throws -> GmailMessage {
    let headers = [
        ["name": "From", "value": "Sender <sender@example.invalid>"],
        ["name": "To", "value": "me@example.com"],
        ["name": "Subject", "value": "Proposal"],
        ["name": "Message-ID", "value": "<\(id)@example.invalid>"]
    ]
    let body: [String: Any] = externalBody.map { ["attachmentId": $0, "size": 20] }
        ?? ["data": Data(text.utf8).base64EncodedString(), "size": text.utf8.count]
    var payload: [String: Any] = ["mimeType": "text/plain", "partId": "0", "headers": headers, "body": body]
    if let attachmentSize {
        payload = ["mimeType": "multipart/mixed", "headers": headers, "parts": [
            ["mimeType": "text/plain", "partId": "0", "body": body],
            ["mimeType": "text/plain", "partId": "1", "filename": "document.txt", "body": ["attachmentId": "file", "size": attachmentSize]]
        ]]
    }
    let object: [String: Any] = ["id": id, "threadId": thread, "historyId": "100", "labelIds": ["INBOX", "UNREAD"], "payload": payload]
    return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: object))
}

private func assistantThreadFixture(_ messages: [GmailMessage], id: String) throws -> GmailThread {
    // Gmail response models are Decodable only; construct a minimal JSON fixture
    // from the content needed by these tests, preserving the MIME part tree.
    func part(_ value: MessagePart) -> [String: Any] {
        var result: [String: Any] = ["mimeType": value.mimeType ?? "", "partId": value.partId ?? ""]
        if let filename = value.filename { result["filename"] = filename }
        result["headers"] = value.headers?.map { ["name": $0.name, "value": $0.value] } ?? []
        if let body = value.body {
            var data: [String: Any] = [:]
            data["data"] = body.data
            data["attachmentId"] = body.attachmentId
            data["size"] = body.size
            result["body"] = data
        }
        if let children = value.parts { result["parts"] = children.map(part) }
        return result
    }
    let values: [[String: Any]] = messages.map {
        var value: [String: Any] = ["id": $0.id, "threadId": $0.threadId, "historyId": $0.historyId ?? "100", "labelIds": $0.labelIds ?? []]
        if let payload = $0.payload { value["payload"] = part(payload) }
        return value
    }
    return try JSONDecoder().decode(GmailThread.self, from: JSONSerialization.data(withJSONObject: ["id": id, "messages": values]))
}
