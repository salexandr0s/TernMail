import Foundation
import GmailAPI
import MailStore
@testable import MessageContent
import Testing
@testable import SyncEngine

@Suite struct ReadReceiptIntegrationTests {
    @Test func sentRequestMatchesReceiptFetchedWithoutOpeningTheThread() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = receiptDraft()
        try await engine.createDraft(draft)
        try await engine.saveDraft(draft.id)
        await engine.sendDueDrafts()
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.requestsReadReceipt } == true)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()
        let upload = try #require(await gmail.uploads.last)
        #expect(MIMEReader.parse(upload.raw).header("Disposition-Notification-To")?.contains("me@example.com") == true)
        #expect(try await cache.readReceiptStatus(accountID: account, rfcMessageID: draft.rfcMessageID)?.recipients.first?.receivedAt == nil)

        let receipt = try receiptMessage(originalID: draft.rfcMessageID)
        await gmail.add(receipt)
        _ = try await engine.fetchMetadata([receipt.id])
        try await engine.retryPendingReadReceipts()
        let status = try #require(try await cache.readReceiptStatus(accountID: account, rfcMessageID: draft.rfcMessageID))
        #expect(status.recipients.first?.receivedAt == receipt.date)
        #expect(await gmail.fullThreadRequests.isEmpty)
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
    }

    @Test func failedSendAndUndoDoNotProduceRequestsButLostSuccessIsReconciled() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let draft = receiptDraft()
        try await engine.createDraft(draft)
        try await engine.sendDraft(draft.id, delay: 10)
        #expect(try await engine.undoSend(draft.id))
        #expect(try await cache.readReceiptStatuses(accountID: account).isEmpty)
        await gmail.failNextDraftCall("send", with: .http(status: 400, reason: "invalidArgument"))
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()
        #expect(try await cache.readReceiptStatuses(accountID: account).isEmpty)

        await gmail.failNextDraftCall("send", with: .transport(.networkConnectionLost), afterApplying: true)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()
        #expect(try await cache.readReceiptStatuses(accountID: account).isEmpty)
        clock.advance(10)
        await engine.sendDueDrafts()
        #expect(try await cache.readReceiptStatuses(accountID: account).count == 1)
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
    }

    @Test func failedOptionalDownloadStaysPendingForNextPassAndTombstonesPreventRecreation() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let receipt = try receiptMessage(originalID: "<tracked@example.com>", detached: true)
        await gmail.add(receipt)
        await gmail.setAttachment("receipt-part", data: report(originalID: "<tracked@example.com>"))
        try await engine.ingestReadReceiptMetadata([receipt])
        await gmail.setMetadataErrors([receipt.id: .transport(.networkConnectionLost)])
        try await engine.retryPendingReadReceipts()
        #expect(try await cache.read { try $0.hasReadReceiptEvent(accountID: account, receiptMessageID: receipt.id) } == false)
        await gmail.setMetadataErrors([:])
        try await engine.retryPendingReadReceipts()
        #expect(try await cache.read { try $0.hasReadReceiptEvent(accountID: account, receiptMessageID: receipt.id) } == true)
        try await cache.write { try $0.deleteReadReceiptData(accountID: account) }
        let deleted = await engine.deletedMessageIDs
        _ = deleted.withLock { $0.insert(receipt.id) }
        try await engine.ingestReadReceipt(receipt)
        #expect(try await cache.read { try $0.hasReadReceiptEvent(accountID: account, receiptMessageID: receipt.id) } == false)
    }

    private func receiptDraft() -> LocalDraft {
        LocalDraft(accountID: account, kind: .new,
            content: DraftContent(to: [EmailAddress(address: "reader@example.com")], requestsReadReceipt: true),
            rfcMessageID: "<tracked@example.com>", now: baseDate)
    }

    private func report(originalID: String) -> Data {
        Data("Original-Message-ID: \(originalID)\r\nFinal-Recipient: rfc822; reader@example.com\r\nDisposition: manual-action/MDN-sent-manually; displayed\r\n".utf8)
    }

    private func receiptMessage(originalID: String, detached: Bool = false) throws -> GmailMessage {
        let body: [String: Any] = detached ? ["attachmentId": "receipt-part", "size": 200] : ["data": report(originalID: originalID).base64EncodedString()]
        return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: [
            "id": "receipt", "threadId": "receipt-thread", "historyId": "200", "internalDate": String(Int(baseDate.addingTimeInterval(60).timeIntervalSince1970 * 1000)),
            "payload": ["mimeType": "multipart/report", "headers": [
                ["name": "Content-Type", "value": "multipart/report; report-type=disposition-notification"],
                ["name": "From", "value": "reader@example.com"], ["name": "To", "value": "me@example.com"]
            ], "parts": [["mimeType": "message/disposition-notification", "body": body]]]
        ]))
    }
}
