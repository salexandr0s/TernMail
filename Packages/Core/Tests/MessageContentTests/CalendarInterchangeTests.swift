import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct CalendarInterchangeTests {
    private func date(_ value: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: value)) }
    private func calendar(_ lines: [String], method: String = "REQUEST") -> Data {
        Data((["BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:" + method] + lines + ["END:VCALENDAR"]).joined(separator: "\r\n").utf8)
    }

    @Test func parsesAllEventsAndRetainsExceptionsAndCancellation() throws {
        let source = calendar([
            "BEGIN:VEVENT", "UID:weekly", "DTSTART;TZID=Europe/Vienna:20261020T090000", "DTEND;TZID=Europe/Vienna:20261020T100000",
            "RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE;TZID=Europe/Vienna:20261027T090000", "DESCRIPTION:First\\nSecond",
            "URL:https://example.com/meeting", "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM", "END:VEVENT",
            "BEGIN:VEVENT", "UID:weekly", "RECURRENCE-ID;TZID=Europe/Vienna:20261103T090000", "STATUS:CANCELLED", "END:VEVENT",
            "BEGIN:VEVENT", "UID:other", "DTSTART;VALUE=DATE:20261104", "DTEND;VALUE=DATE:20261105", "END:VEVENT",
        ])
        let events = try CalendarInterchange.importEvents(source)
        #expect(events.count == 3)
        #expect(events[0].notes == "First\nSecond")
        #expect(events[0].recurrenceLines?.count == 2)
        #expect(events[0].alarms?.first?.relativeSeconds == -900)
        #expect(events[1].isCancelled)
        #expect(!events[1].recurrenceKey.isEmpty)
        let groups = try CalendarInterchange.importGroups(source)
        #expect(groups.count == 2)
        #expect(groups[0].exceptions.count == 1)
        #expect(throws: CalendarInterchangeError.recurrenceExceptionNeedsSeries) {
            try CalendarInterchange.googleEvent(from: events[1])
        }
        let exception = try CalendarInterchange.googleException(from: events[1], parentEventID: "parent")
        #expect(exception.status == "cancelled")
        #expect(exception.originalStartTime?.resolvedDate() == (try date("2026-11-03T08:00:00Z")))
        let exported = try CalendarInterchange.exportInvitations(events)
        #expect(try CalendarInterchange.importEvents(exported).map(\.isCancelled) == [false, true, false])
    }

    @Test func existingStoredInvitationsDecodeAndMimeWrapperRetainsEveryComponent() throws {
        let source = calendar([
            "BEGIN:VEVENT", "UID:one", "DTSTART:20261101T100000Z", "END:VEVENT",
            "BEGIN:VEVENT", "UID:two", "DTSTART:20261102T100000Z", "END:VEVENT",
        ])
        var original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Invitation(data: source))) as? [String: Any])
        for key in ["recurrenceLines", "notes", "url", "alarms", "additionalEvents", "originalEvent", "timeZoneDefinitions"] { original.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(Invitation.self, from: JSONSerialization.data(withJSONObject: original))
        #expect(old.uid == "one")
        #expect(old.recurrenceLines == nil)
        let base64 = source.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data("""
            {"id":"m","threadId":"t","payload":{"mimeType":"text/calendar","body":{"data":"\(base64)","size":\(source.count)}}}
            """.utf8))
        let primary = try #require(CalendarParts.invitation(in: message))
        #expect(primary.uid == "one")
        #expect(primary.additionalEvents?.map(\.uid) == ["two"])
        #expect(CalendarParts.invitations(in: message).map(\.uid) == ["one", "two"])
    }

    @Test func googleExportPreservesAllDayDatesEscapesAndRepeatingTimeZone() throws {
        let vienna = try #require(TimeZone(identifier: "Europe/Vienna"))
        var repeating = GoogleCalendarEvent(id: "weekly", summary: "Café, discussion; next\nline",
                                            start: CalendarDateTime(date: try date("2026-10-20T07:00:00Z"), timeZone: vienna),
                                            end: CalendarDateTime(date: try date("2026-10-20T08:00:00Z"), timeZone: vienna))
        repeating.iCalUID = "original@example.com"
        repeating.sequence = 4
        repeating.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE;TZID=America/New_York:20261027T030000"]
        repeating.description = String(repeating: "ö", count: 100)
        repeating.reminders = CalendarEventReminders(useDefault: false, overrides: [.init(minutes: 15)])
        let allDay = GoogleCalendarEvent(id: "day", summary: "Holiday", start: .init(date: "2026-12-24"), end: .init(date: "2026-12-26"))
        let exported = try CalendarInterchange.exportEvents([repeating, allDay], now: date("2026-10-01T00:00:00Z"))
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.contains("BEGIN:VTIMEZONE"))
        #expect(text.contains("TZID:America/New_York"))
        #expect(text.contains("DTSTART;TZID=Europe/Vienna:20261020T090000"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let imported = try CalendarInterchange.importEvents(exported)
        #expect(imported[0].uid == "original@example.com")
        #expect(imported[0].sequence == 4)
        #expect(imported[0].summary == repeating.summary)
        #expect(imported[0].notes == repeating.description)
        #expect(imported[1].start == .allDay(CalendarDay(year: 2026, month: 12, day: 24)))
        #expect(imported[1].lastDay == CalendarDay(year: 2026, month: 12, day: 25))
        let converted = try CalendarInterchange.googleEvent(from: imported[0])
        #expect(converted.startDate == repeating.startDate)
        #expect(converted.sequence == 4)
        #expect(converted.recurrence == repeating.recurrence)
        #expect(converted.reminders?.overrides?.first?.minutes == 15)
    }

    @Test func unknownRecurringTimeZoneIsRejectedWithoutFlattening() throws {
        let source = calendar([
            "BEGIN:VTIMEZONE", "TZID:Custom Zone", "BEGIN:STANDARD", "DTSTART:19700101T000000",
            "TZOFFSETFROM:+0200", "TZOFFSETTO:+0200", "END:STANDARD", "END:VTIMEZONE",
            "BEGIN:VEVENT", "UID:u", "DTSTART;TZID=Custom Zone:20261020T090000", "DTEND;TZID=Custom Zone:20261020T100000",
            "RRULE:FREQ=WEEKLY", "END:VEVENT",
        ])
        let item = try Invitation(data: source)
        #expect(throws: CalendarInterchangeError.unresolvedTimeZone("Custom Zone")) {
            try CalendarInterchange.googleEvent(from: item)
        }
        let exported = try CalendarInterchange.exportInvitations([item])
        #expect(String(decoding: exported, as: UTF8.self).contains("TZID:Custom Zone"))
    }

    @Test func nonexistentCustomZoneTimeUsesTheOffsetBeforeTheSpringJump() throws {
        let source = calendar([
            "BEGIN:VTIMEZONE", "TZID:Custom Pacific",
            "BEGIN:STANDARD", "DTSTART:20251102T020000", "TZOFFSETFROM:-0700", "TZOFFSETTO:-0800", "END:STANDARD",
            "BEGIN:DAYLIGHT", "DTSTART:20260308T020000", "TZOFFSETFROM:-0800", "TZOFFSETTO:-0700", "END:DAYLIGHT",
            "END:VTIMEZONE", "BEGIN:VEVENT", "UID:gap", "DTSTART;TZID=Custom Pacific:20260308T023000", "DURATION:PT1H", "END:VEVENT",
        ])
        let event = try Invitation(data: source)
        #expect(event.start?.date == (try date("2026-03-08T10:30:00Z")))
        #expect(event.end?.date == (try date("2026-03-08T11:30:00Z")))
    }
}

@Suite struct CalendarDetectionTests {
    private func date(_ value: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: value)) }

    @Test func datesInQuotesAndSignaturesDoNotProduceSuggestions() throws {
        let text = "Meet on July 15, 2031 at 14:00.\n> July 20, 2031 at 15:00\n-- \nJuly 21, 2031 at 16:00"
        let suggestions = CalendarDetection.suggestions(in: text, messageDate: try date("2031-07-01T10:00:00Z"))
        #expect(suggestions.count == 1)
        let first = try #require(suggestions.first)
        #expect(first.sourceText.contains("15"))
        let source = (text as NSString).substring(with: NSRange(location: first.sourceLocation, length: first.sourceLength))
        #expect(source == first.sourceText)
    }

    @Test func datesResolveAgainstTheMessageDate() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        func first(_ text: String, sent: String = "2031-07-01T08:00:00Z") throws -> DetectedCalendarSuggestion {
            try #require(CalendarDetection.suggestions(in: text, messageDate: try date(sent), timeZone: utc).first)
        }
        #expect(try first("Let's meet tomorrow at 3 PM.", sent: "2020-01-05T10:00:00Z").start == (try date("2020-01-06T15:00:00Z")))
        let yearless = try first("Let's meet on July 15 at 3 PM.", sent: "2020-01-05T10:00:00Z")
        #expect(yearless.start == (try date("2020-07-15T15:00:00Z")))
        #expect(!yearless.uncertainties.contains(.dateNeedsReview))
        #expect(try first("Wir sehen uns heute Morgen um 11 Uhr.").start == (try date("2031-07-01T11:00:00Z")))
        #expect(try first("See you Friday at 3pm.").start == (try date("2031-07-04T15:00:00Z")))
        let next = try first("How about next Friday at 3pm?")
        #expect(next.start == (try date("2031-07-04T15:00:00Z")))
        #expect(next.uncertainties.contains(.dateNeedsReview))
        let lunch = try first("Lunch on Friday?")
        #expect(lunch.start == (try date("2031-07-04T12:00:00Z")))
        #expect(lunch.uncertainties.contains(.timeNeedsReview))
    }

    @Test func mentionsWithoutAnUpcomingDayAreNotEvents() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let sent = try date("2031-07-01T08:00:00Z")
        for text in [
            "The online sale is open. Open every day 12PM - 11PM. Book a 2-night stay.",
            "We're open 24/7.", "Mon–Fri 9am–6pm", "Happy Friday!", "I'll send it tomorrow.",
            "Every Monday at 10am", "Last Friday at 3pm was fun.", "We met on June 12.",
            "Offer ends Sunday.", "Valid until 31/12/2031.", "Please reply by Friday, July 4.",
            "Your order will be delivered on Tuesday, July 8.", "Payment will be charged on August 1, 2031.",
            "Sent: Tuesday, July 1, 2031 11:00 AM",
        ] {
            #expect(CalendarDetection.suggestions(in: text, messageDate: sent, timeZone: utc).isEmpty, "\(text)")
        }
        let party = CalendarDetection.suggestions(in: "Please reply by Friday. The party is Saturday at 8pm.", messageDate: sent, timeZone: utc)
        #expect(party.map(\.start) == [try date("2031-07-05T20:00:00Z")])
    }

    @Test func timesCompleteTheirDateAndRangesEndOnTheFollowingDay() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let sent = try date("2031-07-01T08:00:00Z")
        func starts(_ text: String) -> [Date] { CalendarDetection.suggestions(in: text, messageDate: sent, timeZone: utc).map(\.start) }
        #expect(starts("Date: Saturday, July 19, 2031\nTime: 7pm") == [try date("2031-07-19T19:00:00Z")])
        #expect(starts("Treffen am 15.07.2031 um 14 Uhr") == [try date("2031-07-15T14:00:00Z")])
        #expect(starts("Can we meet on Friday (18.07.) at 3pm?") == [try date("2031-07-18T15:00:00Z")])
        #expect(starts("The workshop is on July 15, 2031. It starts July 15, 2031 at 10:00.") == [try date("2031-07-15T10:00:00Z")])
        let conference = try #require(CalendarDetection.suggestions(in: "Conference Nov 3-5", messageDate: sent, timeZone: utc).first)
        #expect(conference.isAllDay)
        #expect(conference.start == (try date("2031-11-03T12:00:00Z")))
        #expect(conference.end == (try date("2031-11-06T12:00:00Z")))
    }

    @Test func forwardedTextAndOversizedInputAreExcluded() throws {
        let text = "Thanks.\n---------- Forwarded message ---------\nMeet July 15, 2031 at 14:00."
        #expect(CalendarDetection.suggestions(in: text, messageDate: try date("2031-07-01T10:00:00Z")).isEmpty)
        #expect(CalendarDetection.suggestions(in: String(repeating: "a", count: CalendarDetection.maximumTextLength + 1), messageDate: .now).isEmpty)
    }

    @Test func htmlQuotationContainersDoNotBecomeNewEvents() throws {
        let text = CalendarDetection.readableText(html: "<div>Meet July 15, 2031 at 14:00.</div><blockquote>July 20, 2031 at 15:00</blockquote><div class='gmail_signature'>July 21, 2031 at 16:00</div>", plainText: nil)
        #expect(text.contains("July 15"))
        #expect(!text.contains("July 20"))
        #expect(!text.contains("July 21"))
        #expect(CalendarDetection.suggestions(in: text, messageDate: .now).count == 1)
    }
}
