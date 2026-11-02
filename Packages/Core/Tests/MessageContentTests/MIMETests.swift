import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct MIMEWriterTests {
    private func calendar(_ methodLines: [String]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0"] + methodLines + [
            "BEGIN:VEVENT", "UID:meeting@example.com", "DTSTAMP:20261030T120000Z",
            "SUMMARY:Café planning", "ORGANIZER:mailto:organizer@example.com",
            "ATTENDEE;CN=Zoë:mailto:zoe@example.com", "END:VEVENT", "END:VCALENDAR", "",
        ]).joined(separator: "\r\n")
    }

    @Test func roundTripKeepsNonASCIIHeadersBodiesAndAttachmentBytes() throws {
        var message = MIMEMessage(from: EmailAddress(name: "Zoë Martín", address: "zoe@example.com"))
        message.replyTo = [EmailAddress(name: "Équipe", address: "team@example.com"), EmailAddress(address: "backup@example.com")]
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
        #expect(parsed.header("Reply-To").map(EmailAddress.parseList) == message.replyTo)
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
        message.replyTo = [EmailAddress(name: "Reply\r\nX-Reply: injected", address: "reply@example.com\r\nX-Address: injected")]

        let parsed = MIMEReader.parse(message.encoded())

        #expect(parsed.header("Bcc") == nil)
        #expect(parsed.header("Cc") == nil)
        #expect(parsed.header("X-Reply") == nil)
        #expect(parsed.header("X-Address") == nil)
        #expect(parsed.headers.filter { $0.name == "Subject" }.count == 1)
    }

    @Test(arguments: [false, true])
    func invitationRepliesAreInlineAlternativesWithOptionalHTMLAndAttachments(includeExtras: Bool) throws {
        let invitation = try Invitation(data: Data(calendar(["METHOD:REQUEST"]).utf8))
        let attendee = try #require(invitation.attendees.first)
        let stamp = try #require(ISO8601DateFormatter().date(from: "2026-10-30T13:00:00Z"))
        let reply = InvitationReply.calendar(replyingTo: invitation, as: attendee, answer: .accepted, now: stamp)
        var message = MIMEMessage(from: EmailAddress(name: attendee.name, address: "zoe@example.com"))
        message.plainText = "Accepted: Café planning"
        message.calendarPart = try MIMEMessage.CalendarPart(text: reply)
        if includeExtras {
            message.html = "<p>Accepted: Café planning</p>"
            message.attachments = [.init(filename: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))]
        }
        let raw = message.encoded()
        let text = String(decoding: raw, as: UTF8.self)
        #expect(raw.allSatisfy { $0 < 0x80 })
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains(where: { $0 == "\n" || $0 == "\r" }))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })

        let parsed = MIMEReader.parse(raw)
        #expect(parsed.header("Reply-To") == nil)
        #expect(parsed.mimeType == (includeExtras ? "multipart/mixed" : "multipart/alternative"))
        let alternative: MIMEEntity
        if includeExtras {
            #expect(parsed.parts.map(\.mimeType) == ["multipart/alternative", "text/plain"])
            #expect(parsed.parts[1].filename == "notes.txt")
            #expect(parsed.parts[1].body == Data("Notes".utf8))
            alternative = try #require(parsed.parts.first)
        } else {
            alternative = parsed
        }
        #expect(alternative.parts.map(\.mimeType) == (includeExtras ? ["text/plain", "text/html", "text/calendar"] : ["text/plain", "text/calendar"]))
        #expect(alternative.parts.first?.text == message.plainText)
        let calendarPart = try #require(alternative.parts.last)
        let parameters = MIMEReader.parameters(of: try #require(calendarPart.header("Content-Type")))
        #expect(parameters["charset"] == "UTF-8")
        #expect(parameters["method"] == "REPLY")
        #expect(calendarPart.header("Content-Disposition") == "inline")
        #expect(calendarPart.filename == nil)
        #expect(calendarPart.text == reply)
        let roundTrip = try Invitation(data: calendarPart.body)
        #expect(roundTrip.uid == invitation.uid)
        #expect(roundTrip.stamp == stamp)
        #expect(roundTrip.method == .reply)
        #expect(roundTrip.attendees.first?.status == .accepted)
    }

    @Test(arguments: [
        [], ["METHOD:"], ["METHOD:REPLY", "METHOD:CANCEL"],
        ["METHOD:REPLY; X-Evil=injected"], ["METHOD:RÉPLY"],
        ["METHOD:" + String(repeating: "A", count: 991)],
    ])
    func calendarMethodsMustBeSingleSafeTokens(methodLines: [String]) {
        #expect(throws: ICalendarError.malformed) {
            try MIMEMessage.CalendarPart(text: self.calendar(methodLines))
        }
    }

    @Test func calendarValidationDropsTrailingRootsAndPreservesMethodSpelling() throws {
        let expected = calendar(["METHOD:reply"])
        let part = try MIMEMessage.CalendarPart(text: expected + calendar(["METHOD:CANCEL"]))
        #expect(part.method == "reply")
        #expect(part.text == expected)
        var message = MIMEMessage(from: EmailAddress(address: "zoe@example.com"))
        message.calendarPart = part
        let encodedCalendar = try #require(MIMEReader.parse(message.encoded()).parts.last)
        #expect(MIMEReader.parameters(of: try #require(encodedCalendar.header("Content-Type")))["method"] == "reply")
        #expect(encodedCalendar.text == expected)
    }

    @Test func longCalendarMethodStaysWithinTheHeaderLineLimit() throws {
        let method = String(repeating: "A", count: 990)
        var message = MIMEMessage(from: EmailAddress(address: "zoe@example.com"))
        message.calendarPart = try MIMEMessage.CalendarPart(text: calendar(["METHOD:" + method]))
        let raw = message.encoded()
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })
        let part = try #require(MIMEReader.parse(raw).parts.last)
        #expect(MIMEReader.parameters(of: try #require(part.header("Content-Type")))["method"] == method)
        #expect(try ICalendar.parse(part.body).property("METHOD")?.value == method)
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

    @Test func typedListsSplitOutsideQuotesCommentsAndAngleBracketsAndAtNewLines() {
        let text = #""Doe, Jane" <jane@example.com>, "Lee \"Ops, EU\"" <lee@example.com>; (Bob, ext) bob@example.com,<a,b@example.com>"#
            + "\ncarol@example.com\r\ndan@example.com;"
        #expect(EmailAddress.splitList(text) == [
            #""Doe, Jane" <jane@example.com>"#, #" "Lee \"Ops, EU\"" <lee@example.com>"#, " (Bob, ext) bob@example.com",
            "<a,b@example.com>", "carol@example.com", "dan@example.com", "",
        ])
        // A quote left open ends with its line, so the next line is still its own entry.
        #expect(EmailAddress.splitList("\"Doe, Jane\nbob@example.com") == ["\"Doe, Jane", "bob@example.com"])
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
