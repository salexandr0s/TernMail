import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct MIMEWriterTests {
    @Test func roundTripKeepsNonASCIIHeadersBodiesAndAttachmentBytes() throws {
        var message = MIMEMessage(from: EmailAddress(name: "Zoë Martín", address: "zoe@example.com"))
        message.to = [EmailAddress(name: "Doe, Jane", address: "jane@example.com"), EmailAddress(address: "bob@example.com")]
        message.cc = [EmailAddress(name: "Ünal", address: "unal@example.com")]
        message.bcc = [EmailAddress(address: "hidden@example.com")]
        message.subject = "Café ☕️ plans for the week, with enough words to need more than one encoded word"
        message.messageID = "<new@example.com>"
        message.inReplyTo = "<parent@example.com>"
        message.references = ["<root@example.com>", "<parent@example.com>"]
        message.plainText = "Line one ends in spaces   \nA = sign, and a long line: " + String(repeating: "word ", count: 40) + "\nnaïve"
        message.html = "<div>Café</div>"
        let pdfBytes = Data((0..<3000).map { UInt8($0 % 256) })
        let longName = "Résumé – final version with a long enough name to need RFC 2231 sections.pdf"
        message.attachments = [
            MIMEMessage.Attachment(filename: longName, mimeType: "application/pdf", data: pdfBytes),
            MIMEMessage.Attachment(filename: "notes \"draft\".txt", mimeType: "text/plain\r\nX-Evil: 1", data: Data("hi".utf8)),
        ]

        let raw = message.encoded(timeZone: try #require(TimeZone(identifier: "UTC")))

        #expect(raw.allSatisfy { $0 < 0x80 })
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.count <= 998 })

        let parsed = MIMEReader.parse(raw)
        #expect(parsed.header("Subject").map(MIMEReader.decodeEncodedWords) == message.subject)
        #expect(parsed.header("From").map(EmailAddress.parseList) == [message.from])
        #expect(parsed.header("To").map(EmailAddress.parseList) == message.to)
        #expect(parsed.header("Cc").map(EmailAddress.parseList) == message.cc)
        #expect(parsed.header("Bcc").map(EmailAddress.parseList) == message.bcc)
        #expect(parsed.header("In-Reply-To") == "<parent@example.com>")
        #expect(parsed.header("References") == "<root@example.com> <parent@example.com>")
        #expect(parsed.header("Date")?.hasSuffix("+0000") == true)

        #expect(parsed.mimeType == "multipart/mixed")
        #expect(parsed.parts.map(\.mimeType) == ["multipart/alternative", "application/pdf", "application/octet-stream"])
        let alternative = try #require(parsed.parts.first)
        #expect(alternative.parts.map(\.mimeType) == ["text/plain", "text/html"])
        #expect(alternative.parts[0].text == message.plainText.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(alternative.parts[1].text == "<div>Café</div>")
        #expect(parsed.parts[1].filename == longName)
        #expect(parsed.parts[1].body == pdfBytes)
        #expect(parsed.parts[2].filename == "notes \"draft\".txt")
        #expect(parsed.parts[2].header("X-Evil") == nil)
    }

    @Test func headerValuesCannotStartNewHeaders() {
        var message = MIMEMessage(from: EmailAddress(name: "A\r\nBcc: evil@example.com", address: "a@example.com"))
        message.subject = "Hi\r\nBcc: evil@example.com"
        message.to = [EmailAddress(address: "b@example.com\r\nCc: evil@example.com")]

        let parsed = MIMEReader.parse(message.encoded())

        #expect(parsed.header("Bcc") == nil)
        #expect(parsed.header("Cc") == nil)
        #expect(parsed.headers.filter { $0.name == "Subject" }.count == 1)
    }
}

@Suite struct MIMEHeaderTests {
    @Test func addressListsHandleQuotesCommentsGroupsAndEncodedNames() {
        let header = #""Doe, Jane" <jane@example.com>, bob@example.com (Bob), Team: a@example.com, b@example.com;, "#
            + "=?UTF-8?B?w5xuYWw=?= <unal@example.com>, not an address, <c@example.com>"

        #expect(EmailAddress.parseList(header) == [
            EmailAddress(name: "Doe, Jane", address: "jane@example.com"),
            EmailAddress(name: "Bob", address: "bob@example.com"),
            EmailAddress(address: "a@example.com"),
            EmailAddress(address: "b@example.com"),
            EmailAddress(name: "Ünal", address: "unal@example.com"),
            EmailAddress(address: "c@example.com"),
        ])
        #expect(EmailAddress(address: "jane@example.com").isValid)
        #expect(!EmailAddress(address: "jane@example").isValid)
        #expect(!EmailAddress(address: "jane doe@example.com").isValid)
    }

    @Test func encodedWordsSplitInsideACharacterDecodeTogether() {
        #expect(MIMEReader.decodeEncodedWords("=?UTF-8?B?ww==?= =?UTF-8?B?qQ==?=") == "é")
        #expect(MIMEReader.decodeEncodedWords("Re: =?ISO-8859-1?Q?caf=E9_ok?= thanks") == "Re: café ok thanks")
    }
}

@Suite struct AttachmentListingTests {
    @Test func partsWithFileNamesOrAttachmentDispositionAreListed() throws {
        let json = """
            {"id":"m1","threadId":"t1","payload":{"mimeType":"multipart/mixed","parts":[
              {"partId":"0","mimeType":"text/plain","filename":"","body":{"size":5,"data":"aGVsbG8"}},
              {"partId":"1","mimeType":"application/pdf","filename":"report.pdf","body":{"attachmentId":"A1","size":1200}},
              {"partId":"2","mimeType":"image/png","filename":"logo.png",
               "headers":[{"name":"Content-ID","value":"<logo>"},{"name":"Content-Disposition","value":"inline; filename=logo.png"}],
               "body":{"attachmentId":"A2","size":300}},
              {"partId":"3","mimeType":"text/csv","filename":"",
               "headers":[{"name":"Content-Type","value":"text/csv; name=\\"data.csv\\""},{"name":"Content-Disposition","value":"attachment"}],
               "body":{"size":4,"data":"YSxiCg"}}
            ]}}
            """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))

        let attachments = MIMEParts.attachments(of: message)

        #expect(attachments.map(\.partID) == ["1", "2", "3"])
        #expect(attachments.map(\.filename) == ["report.pdf", "logo.png", "data.csv"])
        #expect(attachments.map(\.isInline) == [false, true, false])
        #expect(attachments.map(\.attachmentID) == ["A1", "A2", nil])
        #expect(MIMEParts.body(of: message).plainText == "hello")
    }
}
