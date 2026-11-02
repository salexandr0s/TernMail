import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct AssistantResultExportTests {
    @Test func cardOnlyResponseCopiesVisibleMailFactsAndExactSource() throws {
        let source = AssistantSource(accountID: "a", threadID: "t", messageID: "m", partID: "1.2", title: "Source [document]")
        let result = AssistantEmailResult(source: source, senderName: "Sender", senderEmail: "sender@example.invalid",
            subject: "Plan *revision*", snippet: "Reply before Friday.", date: Date(timeIntervalSince1970: 1_600_000_000),
            isUnread: true, isStarred: true, messageCount: 2, accountEmail: "account@example.invalid",
            labels: [.init(accountID: "a", id: "label", name: "Projects", isSystem: false)], reason: "Needs your reply")
        let message = AssistantMessage(isUser: false, text: "", emailResults: [result])
        let exported = AssistantResultExport.markdown(message)
        for fact in ["Sender", "sender@example.invalid", "account@example.invalid", "2020", "Reply before Friday.",
                     "Needs your reply", "Unread", "Starred", "Projects", "2 messages", #"Plan \*revision\*"#] {
            #expect(exported.contains(fact))
        }
        let urlText = try #require(exported.split(separator: "\n").first { $0.hasPrefix("tern://") })
        let url = try #require(URL(string: String(urlText)))
        let link = try #require(MailLink(url: url))
        #expect(link == MailLink(accountID: "a", threadID: "t", messageID: "m", partID: "1.2"))
    }

    @Test func proseOnlyAnswerIncludesItsCitationsAndIncompleteStatus() {
        let source = AssistantSource(accountID: "a", threadID: "t", messageID: "m", partID: nil, title: "Evidence")
        let message = AssistantMessage(isUser: false, text: "Partial answer", sources: [source, source],
            state: .failed, errorMessage: "Connection interrupted.")
        let exported = AssistantResultExport.markdown(message)
        #expect(exported.contains("Response incomplete. Connection interrupted."))
        #expect(exported.contains("Source: Evidence"))
        #expect(exported.components(separatedBy: "tern://conversation").count == 2)
    }

    @Test func taskAndEventExportKeepQualificationsDetailsAndSource() {
        let source = AssistantSource(accountID: "a", threadID: "t", messageID: "m", partID: nil, title: "Meeting email")
        var message = AssistantMessage(isUser: false, text: "Two suggestions.")
        message.taskResults = [.init(source: source, title: "Send proposal", owner: "Alex", notes: "Include the budget.",
                                    dueDate: "2026-12-04", evidence: "Please send it Friday.")]
        var event = GoogleCalendarEvent(summary: "Review")
        event.description = "Bring the proposal."
        event.location = "Room 4"
        event.start = CalendarDateTime(date: "2026-12-04")
        event.end = CalendarDateTime(date: "2026-12-05")
        message.eventResults = [.init(source: source, event: event, evidence: "Review on December 4.",
                                     uncertainties: ["Confirm the room."])]
        let exported = AssistantResultExport.markdown(message)
        for fact in ["Two suggestions.", "Send proposal", "Alex", "Include the budget.", "2026-12-04",
                     "Please send it Friday.", "Review", "Bring the proposal.", "Room 4", "Confirm the room.",
                     "Review on December 4.", "tern://conversation"] {
            #expect(exported.contains(fact))
        }
    }
}
