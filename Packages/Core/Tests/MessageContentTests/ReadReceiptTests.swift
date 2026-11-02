import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct ReadReceiptTests {
    @Test func requestHeaderUsesSafeEncodingAndIsOptional() {
        var message = MIMEMessage(from: EmailAddress(address: "sender@example.com"))
        #expect(MIMEReader.parse(message.encoded()).header("Disposition-Notification-To") == nil)
        message.dispositionNotificationTo = EmailAddress(name: "Sender\r\nX-Evil: injected", address: "sender@example.com")
        let parsed = MIMEReader.parse(message.encoded())
        #expect(parsed.header("Disposition-Notification-To")?.contains("sender@example.com") == true)
        #expect(parsed.header("X-Evil") == nil)
        message.dispositionNotificationTo = EmailAddress(address: "sender@example.com\r\nBcc: evil@example.com")
        let rejected = MIMEReader.parse(message.encoded())
        #expect(rejected.header("Disposition-Notification-To") == nil)
        #expect(rejected.header("Bcc") == nil)
    }

    @Test func foldedReportAndDetachedBytesParseWithoutTreatingOtherDispositionsAsDisplay() throws {
        let data = Data(report(disposition: "displayed", folded: true).utf8)
        let message = try fixture(data: nil)
        #expect(ReadReceiptParser.requiredAttachmentID(of: message) == "part-bytes")
        #expect(ReadReceiptParser.receipt(in: message) == nil)
        let parsed = try #require(ReadReceiptParser.receipt(in: message, attachments: ["part-bytes": data]))
        #expect(parsed.originalMessageID == "<original@example.com>")
        #expect(parsed.recipient == "reader@example.com")
        #expect(parsed.disposition == .displayed)
        for disposition in ["processed", "dispatched", "deleted"] {
            let value = try fixture(data: Data(report(disposition: disposition).utf8))
            #expect(ReadReceiptParser.receipt(in: value)?.disposition.rawValue == disposition)
        }
    }

    @Test func quotedReportsDuplicateFieldsAndErrorReportsNeverConfirmDisplay() throws {
        #expect(ReadReceiptParser.receipt(in: try fixture(data: Data(report().utf8), forwarded: true)) == nil)
        for malformed in [report(disposition: "displayed/error"), report() + "\r\nOriginal-Message-ID: <other@example.com>",
                          report().replacingOccurrences(of: "<original@example.com>", with: "<one@example.com> <two@example.com>")] {
            #expect(ReadReceiptParser.receipt(in: try fixture(data: Data(malformed.utf8))) == nil)
        }
        let tooLarge = Data((report() + String(repeating: " ", count: ReadReceiptParser.maximumReportBytes)).utf8)
        #expect(ReadReceiptParser.receipt(in: try fixture(data: tooLarge)) == nil)
    }

    private func report(disposition: String = "displayed", folded: Bool = false) -> String {
        "Original-Message-ID: <original@example.com>\r\nFinal-Recipient: rfc822;" + (folded ? "\r\n\t" : " ")
            + "Reader@Example.com\r\nDisposition: manual-action/MDN-sent-manually; " + disposition
    }

    private func fixture(data: Data?, forwarded: Bool = false) throws -> GmailMessage {
        let body: [String: Any] = data.map { ["data": $0.base64EncodedString()] } ?? ["attachmentId": "part-bytes", "size": 200]
        var payload: [String: Any] = [
            "mimeType": "multipart/report",
            "headers": [["name": "Content-Type", "value": "multipart/report; report-type=disposition-notification"]],
            "parts": [["mimeType": "message/disposition-notification", "body": body]]
        ]
        if forwarded { payload = ["mimeType": "multipart/mixed", "parts": [["mimeType": "message/rfc822", "parts": [payload]]]] }
        return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: ["id": "r", "threadId": "t", "payload": payload]))
    }
}
