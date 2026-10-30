import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct CalendarInvitationReplyTests {
    @Test func repeatedReplyQueuesOneDraftAndUndoRemovesItsReceipt() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        try await seed(cache, [("invite", "thread", [])])
        let invitation = try invitation(sequence: 1)
        try await cache.write { tx in
            try tx.saveMessageCalendar(MessageCalendarRecord(accountID: account, messageID: "invite", invitation: invitation))
        }
        let first = try await engine.replyToCalendarInvitation(messageID: "invite", uid: invitation.uid,
            recurrenceKey: "", answer: .accepted, delay: 10)
        let second = try await engine.replyToCalendarInvitation(messageID: "invite", uid: invitation.uid,
            recurrenceKey: "", answer: .accepted, delay: 10)
        #expect(first.localDraftID == second.localDraftID)
        let draft = try #require(try await cache.read { try $0.localDraft(id: first.localDraftID) })
        #expect(draft.kind == .invitationReply)
        #expect(draft.to.map(\.address) == ["organizer@example.invalid"])
        #expect(draft.fromAddress == "me@example.com")
        #expect(draft.state == .sending)
        let reply = try Invitation(data: Data(try #require(draft.calendarPart).utf8))
        #expect(reply.method == .reply)
        #expect(reply.attendees.first?.status == .accepted)
        #expect(try await engine.undoSend(first.localDraftID))
        #expect(try await engine.calendarInvitationReply(uid: invitation.uid, recurrenceKey: "") == nil)
    }

    @Test func newerCancellationInAnotherMessagePreventsStaleReplyWithoutDraft() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        try await seed(cache, [("invite", "thread", []), ("cancel", "other", [])])
        let first = try invitation(sequence: 1)
        let cancelled = try invitation(sequence: 2, method: "CANCEL")
        try await cache.write { tx in
            try tx.saveMessageCalendar(MessageCalendarRecord(accountID: account, messageID: "invite", invitation: first))
            try tx.saveMessageCalendar(MessageCalendarRecord(accountID: account, messageID: "cancel", invitation: cancelled))
        }
        await #expect(throws: CalendarInvitationError.self) {
            try await engine.replyToCalendarInvitation(messageID: "invite", uid: first.uid, recurrenceKey: "", answer: .accepted, delay: 10)
        }
        #expect(try await engine.calendarInvitationReply(uid: first.uid, recurrenceKey: "") == nil)
    }

    @Test func siblingOccurrenceRepliesPreserveRecurrenceIdentity() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        try await seed(cache, [("invite", "thread", [])])
        var master = try invitation(sequence: 1)
        let exception = try invitation(sequence: 2, recurrence: "RECURRENCE-ID:20261102T100000Z")
        master.additionalEvents = [exception]
        let stored = master
        try await cache.write { tx in
            try tx.saveMessageCalendar(MessageCalendarRecord(accountID: account, messageID: "invite", invitation: stored))
        }
        let receipt = try await engine.replyToCalendarInvitation(messageID: "invite", uid: exception.uid,
            recurrenceKey: exception.recurrenceKey, answer: .tentative, delay: 10)
        let draft = try #require(try await cache.read { try $0.localDraft(id: receipt.localDraftID) })
        let reply = try Invitation(data: Data(try #require(draft.calendarPart).utf8))
        #expect(reply.recurrenceKey == exception.recurrenceKey)
        #expect(reply.sequence == 2)
    }

    @Test func cachedBodyBackfillsAllInvitationComponentsWithoutReplacingMail() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("invite", "thread", [])])
        let master = try invitation(sequence: 1)
        let exception = try invitation(sequence: 2, recurrence: "RECURRENCE-ID:20261102T100000Z")
        var legacy = master
        legacy.originalEvent = nil
        let stored = legacy
        try await cache.write { tx in
            try tx.saveBodies([MessageBodyRecord(accountID: account, messageID: "invite", html: nil, plainText: "Cached mail body", fetchedAt: baseDate)],
                calendars: [MessageCalendarRecord(accountID: account, messageID: "invite", invitation: stored)])
        }
        let exported = try CalendarInterchange.exportInvitations([master, exception])
        let text = String(decoding: exported, as: UTF8.self).replacingOccurrences(of: "BEGIN:VCALENDAR\r\n", with: "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\n")
        let encoded = Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let remote = try JSONDecoder().decode(GmailThread.self, from: Data("""
            {"id":"thread","messages":[{"id":"invite","threadId":"thread","historyId":"1","payload":{"mimeType":"text/calendar","body":{"data":"\(encoded)"}}}]}
            """.utf8))
        await gmail.setThread(remote)
        try await engine.refreshCalendarInvitations(threadID: "thread")
        let records = try await engine.calendarInvitations(threadID: "thread")
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.invitation.originalEvent != nil })
        #expect(try await cache.read { try $0.body(messageID: "invite", accountID: account)?.plainText } == "Cached mail body")
    }

    private func invitation(sequence: Int, method: String = "REQUEST", recurrence: String = "") throws -> Invitation {
        try Invitation(data: Data([
            "BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:\(method)", "BEGIN:VEVENT", "UID:meeting@example.invalid",
            "DTSTAMP:20261030T090000Z", "SEQUENCE:\(sequence)", "DTSTART:20261102T100000Z", "DURATION:PT1H",
            recurrence, "ORGANIZER:mailto:organizer@example.invalid", "ATTENDEE;RSVP=TRUE:mailto:me@example.com",
            "SUMMARY:Planning", "END:VEVENT", "END:VCALENDAR", "",
        ].filter { !$0.isEmpty }.joined(separator: "\r\n").utf8))
    }
}
