import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct InvitationBannerTests {
    @Test func accountWideVersionsRefreshAnUnchangedOpenInvitationAndIgnoreAttendeeReplies() throws {
        let model = EmailCalendarModel()
        let request = try invitation()
        let message = EmailCalendarMessage(id: "open", subject: "Planning", date: .now, text: "", invitations: [request])
        model.update(messages: [message], addresses: ["me@example.com"])
        let revision = model.revision
        #expect(model.items.first?.isOutdated == false)

        let reply = try invitation(method: "REPLY", sequence: 50)
        model.update(messages: [message], addresses: ["me@example.com"], invitationState: .init(invitations: [
            .init(accountID: "a", messageID: "reply-in-another-thread", invitation: reply)
        ]))
        #expect(model.items.first?.isOutdated == false)

        let later = try invitation(stamp: "20310702T090000Z")
        model.update(messages: [message], addresses: ["me@example.com"], invitationState: .init(invitations: [
            .init(accountID: "a", messageID: "newer-in-another-thread", invitation: later)
        ]))
        #expect(model.revision == revision)
        #expect(model.items.first?.isOutdated == true)
        #expect(model.items.first?.canReview == false)

        let occurrence = try invitation(recurrence: "RECURRENCE-ID:20310715T140000Z\r\n")
        let occurrenceMessage = EmailCalendarMessage(id: "occurrence", subject: "Planning", date: .now, text: "", invitations: [occurrence])
        let cancel = try invitation(method: "CANCEL", sequence: 2)
        model.update(messages: [occurrenceMessage], addresses: ["me@example.com"], invitationState: .init(invitations: [
            .init(accountID: "a", messageID: "whole-series-cancellation", invitation: cancel)
        ]))
        #expect(model.items.first?.isOutdated == true)
        #expect(model.items.first?.event?.startDate != nil)
        #expect(model.items.first?.event?.originalStartTime != nil)
    }

    @Test func savedAnswerAndUndoRefreshWithoutMessageChangesAndSenderWarningUsesParsedAddress() throws {
        let model = EmailCalendarModel()
        var message = EmailCalendarMessage(id: "open", subject: "Planning", date: .now, text: "", invitations: [try invitation()],
            sender: "Different Sender <other@example.com>")
        let receipt = InvitationReplyRecord(accountID: "a", uid: "planning@example.com", recurrenceKey: "",
            participationStatus: .accepted, localDraftID: "draft", queuedAt: .now)
        model.update(messages: [message], addresses: ["me@example.com"], invitationState: .init(replies: [receipt]))
        let revision = model.revision
        let answered = try #require(model.items.first)
        #expect(answered.previousAnswer == .accepted)
        #expect(answered.authenticityWarning?.contains("organizer@example.com") == true)
        #expect(EmailCalendarPresentation(item: answered, calendar: .current).answerLine?.contains("Accepted") == true)
        model.update(messages: [message], addresses: ["me@example.com"])
        #expect(model.revision == revision)
        #expect(model.items.first?.previousAnswer == nil)
        message.sender = "Organizer <ORGANIZER@EXAMPLE.COM>"
        model.update(messages: [message], addresses: ["me@example.com"])
        #expect(model.items.first?.authenticityWarning == nil)
    }

    @Test func attendeeRepliesAppearOnlyForTheOrganizerAndNeverOfferPersonalCopy() throws {
        let reply = try invitation(method: "REPLY")
        let message = EmailCalendarMessage(id: "reply", subject: "Planning", date: .now, text: "", invitations: [reply], sender: "me@example.com")
        let model = EmailCalendarModel()
        model.update(messages: [message], addresses: ["me@example.com"])
        #expect(model.items.isEmpty)
        model.update(messages: [message], addresses: ["ORGANIZER@example.com"])
        let item = try #require(model.items.first)
        #expect(item.kind == .response)
        #expect(!item.canReview)
        #expect(item.authenticityWarning == nil)
        let presentation = EmailCalendarPresentation(item: item, calendar: .current)
        #expect(presentation.responseLines == ["Guest: Accepted"])
    }

    @Test func eventDetailsKeepOriginalZoneAndRecurrenceAlongsideLocalTime() throws {
        let invitation = try invitation(recurrence: "RRULE:FREQ=WEEKLY\r\n", start: "DTSTART;TZID=Europe/Vienna:20310715T140000")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let event = try CalendarInterchange.googleEvent(from: invitation, fallbackTimeZone: calendar.timeZone)
        let item = EmailCalendarItem(id: "event", messageID: "message", title: "Planning", evidence: "", kind: .invitation,
            event: event, invitation: invitation)
        let presentation = EmailCalendarPresentation(item: item, calendar: calendar)
        #expect(presentation.dateLine.contains("08:00"))
        #expect(presentation.originalTimeZoneLine?.contains("14:00") == true)
        #expect(presentation.originalTimeZoneLine?.contains("Europe/Vienna") == true)
        #expect(presentation.organizer == "Organizer <organizer@example.com>")
        #expect(presentation.recurrenceNote != nil)
    }

    private func invitation(method: String = "REQUEST", sequence: Int = 1, stamp: String = "20310701T090000Z",
                            recurrence: String = "", start: String = "DTSTART:20310715T140000Z") throws -> Invitation {
        try Invitation(data: Data(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Tern Test//EN\r\nMETHOD:\(method)\r\n" +
            "BEGIN:VEVENT\r\nUID:planning@example.com\r\nSEQUENCE:\(sequence)\r\nDTSTAMP:\(stamp)\r\n" +
            "SUMMARY:Planning\r\n\(start)\r\n\(recurrence)" +
            "ORGANIZER;CN=Organizer:mailto:organizer@example.com\r\n" +
            "ATTENDEE;CN=Guest;PARTSTAT=ACCEPTED:mailto:me@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").utf8))
    }
}
