import Foundation
import MessageContent
import Testing
@testable import MailStore

@Suite struct CalendarInvitationStateTests {
    @Test(.timeLimit(.minutes(1))) func accountStreamObservesOtherThreadsAndRemovalOfAnUndoneAnswer() async throws {
        let cache = try MailCache.inMemory()
        var iterator = cache.calendarInvitationState(accountID: "a").makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.invitations.isEmpty)
        #expect(initial.replies.isEmpty)
        let invitation = try Invitation(data: Data(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\n" +
            "BEGIN:VEVENT\r\nUID:event@example.com\r\nDTSTART:20310715T140000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").utf8))
        try await cache.write { tx in
            for account in ["a", "b"] {
                let message = MessageRecord(accountID: account, id: "m", threadID: "another-thread", historyID: 1,
                    date: .now, snippet: "", sender: "organizer@example.com", recipients: "me@example.com", cc: nil,
                    subject: "Event", sizeEstimate: 100)
                _ = try tx.upsertMessages([.init(record: message, labelIDs: [])])
                try tx.saveMessageCalendar(.init(accountID: account, messageID: "m", invitation: invitation))
            }
        }
        let changed = try #require(try await iterator.next())
        #expect(changed.invitations.map(\.accountID) == ["a"])
        #expect(changed.invitations.first?.messageID == "m")

        let answer = InvitationReplyRecord(accountID: "a", uid: invitation.uid, recurrenceKey: "",
            participationStatus: .accepted, localDraftID: "draft", queuedAt: Date(timeIntervalSince1970: 1_900_000_000))
        try await cache.write { tx in try tx.saveInvitationReply(answer) }
        let answered = try #require(try await iterator.next())
        #expect(answered.replies == [answer])
        try await cache.write { tx in _ = try tx.deleteInvitationReply(localDraftID: "draft", accountID: "a") }
        let undone = try #require(try await iterator.next())
        #expect(undone.replies.isEmpty)
        #expect(undone.invitations == changed.invitations)
    }
}
