import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct InvitationTests {
    private func calendar(method: String? = "REQUEST", _ body: [String]) -> Data {
        let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN"]
            + (method.map { ["METHOD:" + $0] } ?? []) + body + ["END:VCALENDAR"]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private func event(method: String? = "REQUEST", _ lines: [String], timeZones: [String] = []) -> Data {
        calendar(method: method, timeZones + ["BEGIN:VEVENT"] + lines + ["END:VEVENT"])
    }

    private func utc(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func message(parts: String) throws -> GmailMessage {
        let json = """
        {"id":"m1","threadId":"t1","payload":{"mimeType":"multipart/mixed","parts":[\(parts)]}}
        """
        return try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    private let pacific = [
        "BEGIN:VTIMEZONE", "TZID:Pacific Standard Time",
        "BEGIN:STANDARD", "DTSTART:16010101T020000", "TZOFFSETFROM:-0700", "TZOFFSETTO:-0800",
        "RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11", "END:STANDARD",
        "BEGIN:DAYLIGHT", "DTSTART:16010101T020000", "TZOFFSETFROM:-0800", "TZOFFSETTO:-0700",
        "RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3", "END:DAYLIGHT",
        "END:VTIMEZONE",
    ]

    // MARK: Reading

    @Test func foldsWithASpaceOrATabAreUndoneEvenInsideACharacter() throws {
        var bytes = Data("BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:u1\r\nSUMMARY:Caf".utf8)
        // "é" is C3 A9, folded between its two bytes.
        bytes.append(0xC3)
        bytes.append(contentsOf: "\r\n ".utf8)
        bytes.append(0xA9)
        bytes.append(contentsOf: " au lait\r\nLOCATION:Room\r\n\t 4\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        let invitation = try Invitation(data: bytes)
        #expect(invitation.summary == "Café au lait")
        #expect(invitation.location == "Room 4")
    }

    @Test func textEscapesAndQuotedParameterValuesAreRead() throws {
        let invitation = try Invitation(data: event([
            "UID:u1",
            #"SUMMARY:Lunch\, then \; talk\nSecond line\\done"#,
            #"ATTENDEE;CN="Lee, Ann: PM; Team";PARTSTAT=TENTATIVE:mailto:ann@example.com"#,
        ]))
        #expect(invitation.summary == "Lunch, then ; talk\nSecond line\\done")
        let attendee = try #require(invitation.attendees.first)
        #expect(attendee.name == "Lee, Ann: PM; Team")
        #expect(attendee.status == .tentative)
    }

    @Test(arguments: [
        ("REQUEST", Invitation.Method.request),
        ("CANCEL", .cancel),
        ("reply", .reply),
        ("X-PROPOSE", .other("X-PROPOSE")),
    ])
    func methodsAreRead(written: String, method: Invitation.Method) throws {
        let invitation = try Invitation(data: event(method: written, ["UID:u1"]))
        #expect(invitation.method == method)
        #expect(invitation.isCancelled == (method == .cancel))
    }

    @Test func startsAndEndsResolveInEachForm() throws {
        func read(_ lines: [String]) throws -> Invitation {
            try Invitation(data: event(["UID:u1"] + lines))
        }
        let inUTC = try read(["DTSTART:20261105T150000Z", "DTEND:20261105T160000Z"])
        #expect(inUTC.start == .utc(try utc("2026-11-05T15:00:00Z")))
        #expect(inUTC.end == .utc(try utc("2026-11-05T16:00:00Z")))

        let inParis = try read(["DTSTART;TZID=Europe/Paris:20260701T090000", "DURATION:PT1H30M"])
        #expect(inParis.start == .zoned(try utc("2026-07-01T07:00:00Z"), zone: "Europe/Paris", utcOffset: 7200))
        #expect(inParis.end?.date == (try utc("2026-07-01T08:30:00Z")))

        let floating = try read(["DTSTART:20261105T090000"])
        #expect(floating.start == .floating(LocalDateTime(day: CalendarDay(year: 2026, month: 11, day: 5), hour: 9)))
        #expect(floating.end == floating.start)

        let holidays = try read(["DTSTART;VALUE=DATE:20261224", "DTEND;VALUE=DATE:20261226"])
        #expect(holidays.lastDay == CalendarDay(year: 2026, month: 12, day: 25))
        let oneDay = try read(["DTSTART;VALUE=DATE:20261231"])
        #expect(oneDay.end == .allDay(CalendarDay(year: 2027, month: 1, day: 1)))
        #expect(oneDay.lastDay == CalendarDay(year: 2026, month: 12, day: 31))

        let unknownZone = try read(["DTSTART;TZID=Nowhere Standard Time:20261105T090000"])
        #expect(unknownZone.start == .unresolved(LocalDateTime(day: CalendarDay(year: 2026, month: 11, day: 5), hour: 9), zone: "Nowhere Standard Time"))
    }

    @Test(arguments: [
        ("20260307T100000", "P1D", "2026-03-08T17:00:00Z", -25_200),
        ("20260307T100000", "PT24H", "2026-03-08T18:00:00Z", -25_200),
        ("20260308T013000", "PT2H", "2026-03-08T11:30:00Z", -25_200),
        ("20260307T013000", "P1DT2H", "2026-03-08T11:30:00Z", -25_200),
        ("20260301T100000", "P1W", "2026-03-08T17:00:00Z", -25_200),
        ("20261031T100000", "P1D", "2026-11-01T18:00:00Z", -28_800),
        ("20261031T100000", "PT24H", "2026-11-01T17:00:00Z", -28_800),
        // Ends in the second 01:30, after the offset has changed.
        ("20261101T003000", "PT2H", "2026-11-01T09:30:00Z", -28_800),
    ])
    func durationsApplyDaysBeforeElapsedTimeAcrossDST(local: String, duration: String, expected: String, offset: Int) throws {
        for tzid in ["America/Los_Angeles", "Pacific Standard Time"] {
            let invitation = try Invitation(data: event([
                "UID:u1", "DTSTART;TZID=\(tzid):\(local)", "DURATION:\(duration)",
            ], timeZones: pacific))
            #expect(invitation.end == .zoned(try utc(expected), zone: tzid, utcOffset: offset))
        }
    }

    @Test func durationsKeepFloatingUnknownAndAllDayTimesAsWritten() throws {
        let expected = LocalDateTime(day: CalendarDay(year: 2026, month: 3, day: 8), hour: 3, minute: 30)
        let floating = try Invitation(data: event(["UID:u1", "DTSTART:20260307T013000", "DURATION:P1DT2H"]))
        #expect(floating.end == .floating(expected))
        let unknown = try Invitation(data: event(["UID:u1", "DTSTART;TZID=Unknown:20260307T013000", "DURATION:P1DT2H"]))
        #expect(unknown.end == .unresolved(expected, zone: "Unknown"))
        let allDay = try Invitation(data: event(["UID:u1", "DTSTART;VALUE=DATE:20260307", "DURATION:P1W"]))
        #expect(allDay.end == .allDay(CalendarDay(year: 2026, month: 3, day: 14)))
    }

    @Test(arguments: [
        // The days around 2026's changes, on 8 March and 1 November.
        ("20260307T100000", "2026-03-07T18:00:00Z"),
        ("20260309T100000", "2026-03-09T17:00:00Z"),
        // The November onset is 02:00 on the old offset, so 01:30 is still daylight time.
        ("20261101T013000", "2026-11-01T08:30:00Z"),
        ("20261101T023000", "2026-11-01T10:30:00Z"),
        ("20260115T120000", "2026-01-15T20:00:00Z"),
    ])
    func aWindowsZoneResolvesThroughItsVTimeZone(local: String, expected: String) throws {
        let invitation = try Invitation(data: event(["UID:u1", "DTSTART;TZID=Pacific Standard Time:" + local], timeZones: pacific))
        let start = try #require(invitation.start)
        guard case .zoned(let date, let zone, _) = start else {
            Issue.record("Expected a zoned time, got \(start)")
            return
        }
        #expect(date == (try utc(expected)))
        #expect(zone == "Pacific Standard Time")
    }

    @Test func theBlockWithTheLatestOnsetBeforeTheEventWins() throws {
        let zone = [
            "BEGIN:VTIMEZONE", "TZID:Example Zone",
            "BEGIN:STANDARD", "DTSTART:19700101T000000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0100", "END:STANDARD",
            "BEGIN:DAYLIGHT", "DTSTART:19800330T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200",
            "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU;UNTIL=20190331T010000Z", "END:DAYLIGHT",
            "BEGIN:STANDARD", "DTSTART:19801026T030000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100",
            "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU;UNTIL=20191027T010000Z", "END:STANDARD",
            "BEGIN:STANDARD", "DTSTART:20200101T000000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0300", "END:STANDARD",
            "END:VTIMEZONE",
        ]
        func start(_ local: String) throws -> Date? {
            try Invitation(data: event(["UID:u1", "DTSTART;TZID=Example Zone:" + local], timeZones: zone)).start?.date
        }
        #expect(try start("20150115T120000") == (try utc("2015-01-15T11:00:00Z")))
        #expect(try start("20150701T120000") == (try utc("2015-07-01T10:00:00Z")))
        // The last daylight onset before UNTIL still counts.
        #expect(try start("20190701T120000") == (try utc("2019-07-01T10:00:00Z")))
        #expect(try start("20260701T120000") == (try utc("2026-07-01T09:00:00Z")))
    }

    @Test func attendeesKeepTheirStatusAndMatchAddressesIgnoringCase() throws {
        let invitation = try Invitation(data: event([
            "UID:u1",
            "ORGANIZER;CN=Boss:mailto:boss@example.com",
            "ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE:MAILTO:Ann@Example.COM",
            "ATTENDEE;PARTSTAT=X-UNKNOWN:mailto:bo@example.com",
            "ATTENDEE;CUTYPE=RESOURCE:urn:uuid:room-1",
        ]))
        #expect(invitation.organizer?.email == "boss@example.com")
        #expect(invitation.attendees.map(\.status) == [.accepted, .needsAction, .needsAction])
        #expect(invitation.attendees.map(\.email) == ["Ann@Example.COM", "bo@example.com", nil])

        let me = try #require(invitation.attendee(matchingAnyOf: ["other@example.com", " ann@example.com"]))
        #expect(me.calendarAddress == "MAILTO:Ann@Example.COM")
        #expect(me.rsvp)
        #expect(invitation.attendee(matchingAnyOf: ["room-1@example.com"]) == nil)
    }

    @Test func theMasterEventWinsOverAnOverride() throws {
        let both = calendar([
            "BEGIN:VEVENT", "UID:u1", "RECURRENCE-ID:20261112T150000Z", "SUMMARY:Moved once", "END:VEVENT",
            "BEGIN:VEVENT", "UID:u1", "DTSTART:20261105T150000Z", "RRULE:FREQ=WEEKLY", "SUMMARY:Weekly", "END:VEVENT",
        ])
        let master = try Invitation(data: both)
        #expect(master.summary == "Weekly")
        #expect(master.repeats)
        #expect(master.recurrenceKey.isEmpty)

        let single = try Invitation(data: event(["UID:u1", "RECURRENCE-ID;TZID=Europe/Paris:20261112T160000"]))
        #expect(single.recurrenceKey == "20261112T150000Z")
    }

    @Test func malformedInputFailsAndJunkLinesAreSkipped() throws {
        #expect(throws: ICalendarError.noEvent) { try Invitation(data: self.calendar([])) }
        #expect(throws: ICalendarError.missingUID) { try Invitation(data: self.event(["SUMMARY:No ID"])) }
        #expect(throws: ICalendarError.malformed) {
            try Invitation(data: Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u1\r\n".utf8))
        }
        #expect(throws: ICalendarError.malformed) {
            try Invitation(data: Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u1\r\nEND:VCALENDAR\r\n".utf8))
        }
        #expect(throws: ICalendarError.noCalendar) { try Invitation(data: Data("Hello\r\n".utf8)) }
        #expect(throws: ICalendarError.tooLarge) {
            try Invitation(data: Data(repeating: 0x20, count: ICalendar.maxSize + 1))
        }

        let junk = event(["UID:u1", "this is not a property", ":no name", "X-BAD;NOVALUE:x", "SUMMARY:Kept"])
        #expect(try Invitation(data: junk).summary == "Kept")

        var latin1 = Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u1\r\nSUMMARY:Caf".utf8)
        latin1.append(0xE9)
        latin1.append(contentsOf: "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        #expect(try Invitation(data: latin1, charset: "iso-8859-1").summary == "Café")
    }

    // MARK: Finding the part

    @Test func theCalendarAlternativeWinsOverAnAttachedFile() throws {
        let inline = encoded(event(["UID:inline"]))
        let json = """
        {"id":"m1","threadId":"t1","payload":{"mimeType":"multipart/mixed","parts":[
          {"partId":"0","mimeType":"multipart/alternative","parts":[
            {"partId":"0.0","mimeType":"text/plain","body":{"size":5,"data":"aGVsbG8"}},
            {"partId":"0.1","mimeType":"text/calendar",
             "headers":[{"name":"Content-Type","value":"text/calendar; charset=UTF-8; method=REQUEST"}],
             "body":{"size":400,"data":"\(inline)"}}]},
          {"partId":"1","mimeType":"application/ics","filename":"invite.ics","body":{"attachmentId":"A1","size":400}}
        ]}}
        """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        #expect(CalendarParts.candidates(in: message).map(\.partID) == ["0.1", "1"])
        #expect(CalendarParts.requiredAttachmentID(of: message) == nil)
        #expect(CalendarParts.invitation(in: message, attachments: ["A1": event(["UID:attached"])])?.uid == "inline")

        // Sent by ID only: downloaded when within the cap, and an attached
        // file without a METHOD isn't an invitation.
        let attachedOnly = """
        {"id":"m2","threadId":"t1","payload":{"mimeType":"multipart/mixed","parts":[
          {"partId":"0","mimeType":"text/plain","body":{"size":5,"data":"aGVsbG8"}},
          {"partId":"1","mimeType":"text/calendar","filename":"export.ics","body":{"attachmentId":"A2","size":400}}
        ]}}
        """
        let second = try JSONDecoder().decode(GmailMessage.self, from: Data(attachedOnly.utf8))
        #expect(CalendarParts.requiredAttachmentID(of: second) == "A2")
        #expect(CalendarParts.invitation(in: second, attachments: ["A2": event(method: nil, ["UID:export"])]) == nil)
        #expect(CalendarParts.invitation(in: second, attachments: ["A2": event(["UID:invite"])])?.uid == "invite")
    }

    @Test func calendarDownloadsAreOptInAndStopAtTheFirstUsableCandidate() throws {
        let message = try message(parts: """
        {"partId":"0","mimeType":"application/ics","filename":"later.ics","body":{"attachmentId":"later","size":400}},
        {"partId":"1","mimeType":"text/calendar","body":{"attachmentId":"first","size":400}},
        {"partId":"2","mimeType":"text/calendar","body":{"attachmentId":"second","size":400}},
        {"partId":"3","mimeType":"text/plain","body":{"attachmentId":"text","size":5}}
        """)
        #expect(CalendarParts.candidates(in: message).map(\.attachmentID) == ["first", "second", "later"])
        #expect(MIMEParts.requiredAttachmentIDs(of: message) == ["text"])
        #expect(MIMEParts.requiredAttachmentIDs(of: message, includingCalendars: true) == ["text", "first"])
        var data = ["first": Data("not a calendar".utf8)]
        #expect(CalendarParts.requiredAttachmentID(of: message, attachments: data, attemptedAttachmentIDs: ["first"]) == "second")
        data["second"] = event(["UID:second"])
        #expect(CalendarParts.requiredAttachmentID(of: message, attachments: data, attemptedAttachmentIDs: ["first", "second"]) == nil)
        #expect(CalendarParts.invitation(in: message, attachments: data)?.uid == "second")
    }

    @Test func calendarCapsAndMalformedInlinePartsAllowLaterCandidates() throws {
        var valid = event(["UID:valid"])
        valid.append(Data(repeating: 0x20, count: ICalendar.maxSize - valid.count))
        var oversized = valid
        oversized.append(0x20)
        let message = try message(parts: """
        {"mimeType":"text/calendar","body":{"size":4,"data":"\(encoded(Data("bad".utf8)))"}},
        {"mimeType":"text/calendar","body":{"size":100,"data":"\(encoded(oversized))"}},
        {"mimeType":"text/calendar","body":{"attachmentId":"reportedLarge","size":\(ICalendar.maxSize + 1)}},
        {"mimeType":"text/calendar","body":{"attachmentId":"actualLarge","size":100}},
        {"mimeType":"application/ics","filename":"export.ics","body":{"attachmentId":"export","size":100}},
        {"mimeType":"application/octet-stream","filename":"invite.ICS","body":{"attachmentId":"valid","size":\(ICalendar.maxSize)}}
        """)
        #expect(CalendarParts.requiredAttachmentID(of: message) == "actualLarge")
        var data = ["reportedLarge": valid, "actualLarge": oversized]
        #expect(CalendarParts.invitation(in: message, attachments: data) == nil)
        #expect(CalendarParts.requiredAttachmentID(of: message, attachments: data, attemptedAttachmentIDs: ["actualLarge"]) == "export")
        data["export"] = event(method: nil, ["UID:export"])
        #expect(CalendarParts.requiredAttachmentID(of: message, attachments: data, attemptedAttachmentIDs: ["actualLarge", "export"]) == "valid")
        data["valid"] = valid
        #expect(CalendarParts.invitation(in: message, attachments: data)?.uid == "valid")
        #expect(CalendarParts.requiredAttachmentID(of: message, attachments: data) == nil)
    }

    @Test func calendarDownloadAttemptsAreBoundedAndDeduplicated() throws {
        let parts = ["a", "a", "b", "c", "d", "e"].map { id in
            """
            {"mimeType":"text/calendar","body":{"attachmentId":"\(id)","size":\(ICalendar.maxSize)}}
            """
        }.joined(separator: ",")
        let message = try message(parts: parts)
        var attempted: Set<String> = []
        var requested: [String] = []
        while let id = CalendarParts.requiredAttachmentID(of: message, attemptedAttachmentIDs: attempted) {
            attempted.insert(id)
            requested.append(id)
        }
        #expect(requested == ["a", "b", "c", "d"])
    }

    @Test func calendarsInsideAttachedMultipartOrMessagesAreIgnored() throws {
        let message = try message(parts: """
        {"mimeType":"multipart/alternative","headers":[{"name":"Content-Disposition","value":"attachment"}],"parts":[
          {"mimeType":"text/calendar","body":{"attachmentId":"hiddenMultipart","size":100}}]},
        {"mimeType":"message/rfc822","parts":[
          {"mimeType":"text/calendar","body":{"attachmentId":"hiddenMessage","size":100}}]},
        {"partId":"visible","mimeType":"application/ics","filename":"visible.ics","body":{"attachmentId":"visible","size":100}}
        """)
        #expect(CalendarParts.candidates(in: message).map(\.partID) == ["visible"])
        #expect(MIMEParts.requiredAttachmentIDs(of: message, includingCalendars: true) == ["visible"])
        #expect(CalendarParts.invitation(in: message, attachments: [
            "hiddenMultipart": event(["UID:hiddenMultipart"]), "hiddenMessage": event(["UID:hiddenMessage"]),
        ]) == nil)
    }

    // MARK: Replying

    @Test func aReplyCopiesWhatTheOrganizerMatchesAndNothingElse() throws {
        let request = try Invitation(data: event([
            "UID:040000008200E00074C5B7101A82E008@example.com",
            "RECURRENCE-ID;TZID=Pacific Standard Time:20261105T100000",
            "SEQUENCE:3",
            "DTSTART;TZID=Pacific Standard Time:20261105T100000",
            "DTEND;TZID=Pacific Standard Time:20261105T110000",
            "ORGANIZER;CN=Organizer:mailto:boss@example.com",
            #"SUMMARY:Planning\, Q4 – with a title long enough to fold more than once ✓ ✓ ✓"#,
            "ATTENDEE;CN=Ann;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:MAILTO:Ann@Example.com",
            "ATTENDEE;CN=Bo:mailto:bo@example.com",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM",
        ], timeZones: pacific))
        let me = try #require(request.attendee(matchingAnyOf: ["ann@example.com"]))
        let now = try utc("2026-10-29T12:00:00Z")
        let text = InvitationReply.calendar(replyingTo: request, as: me, answer: .accepted, now: now)

        #expect(text.hasSuffix("\r\n"))
        let lines = text.components(separatedBy: "\r\n").dropLast()
        #expect(lines.allSatisfy { !$0.contains("\n") && !$0.contains("\r") && $0.utf8.count <= 75 })
        #expect(lines.contains { $0.hasPrefix(" ") })

        let parsed = try ICalendar.parse(Data(text.utf8))
        #expect(parsed.property("VERSION")?.value == "2.0")
        #expect(parsed.property("PRODID")?.value == InvitationReply.productID)
        #expect(parsed.components(named: "VTIMEZONE").first?.property("TZID")?.value == "Pacific Standard Time")
        let vevent = try #require(parsed.components(named: "VEVENT").first)
        #expect(vevent.components.isEmpty)
        #expect(vevent.property("DTSTART") == nil && vevent.property("DTEND") == nil)
        #expect(vevent.property("RECURRENCE-ID")?.value == "20261105T100000")
        let attendees = vevent.properties(named: "ATTENDEE")
        #expect(attendees.count == 1)
        #expect(attendees.first?.value == "MAILTO:Ann@Example.com")
        #expect(attendees.first?.parameter("RSVP") == nil)

        let reply = try Invitation(calendar: parsed)
        #expect(reply.method == .reply)
        #expect(reply.uid == request.uid)
        #expect(reply.sequence == 3)
        #expect(reply.stamp == now)
        #expect(reply.summary == request.summary)
        #expect(reply.organizer == request.organizer)
        #expect(reply.recurrenceKey == request.recurrenceKey && reply.recurrenceKey == "20261105T180000Z")
        #expect(reply.attendees.map(\.status) == [.accepted])
        #expect(reply.attendees.first?.name == "Ann")
        #expect(InvitationReply.subject(for: .tentative, summary: "Planning") == "Tentatively accepted: Planning")
    }

    @Test func aReplyConvertsAnOccurrenceToUTCWhenTheRequestHadNoVTimeZone() throws {
        let request = try Invitation(data: event([
            "UID:u1",
            "RECURRENCE-ID;TZID=America/New_York:20261105T100000",
            "ORGANIZER:mailto:boss@example.com",
            "ATTENDEE:mailto:ann@example.com",
        ]))
        let me = try #require(request.attendees.first)
        let parsed = try ICalendar.parse(Data(InvitationReply.calendar(replyingTo: request, as: me, answer: .declined).utf8))
        #expect(parsed.components(named: "VTIMEZONE").isEmpty)
        let recurrenceID = try #require(parsed.components(named: "VEVENT").first?.property("RECURRENCE-ID"))
        #expect(recurrenceID.value == "20261105T150000Z")
        #expect(recurrenceID.parameter("TZID") == nil)
    }
}
