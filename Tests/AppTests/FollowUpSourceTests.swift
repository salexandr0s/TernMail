import Foundation
import Testing
import TernAI
@testable import MailStore
@testable import Tern

@Suite @MainActor struct FollowUpSourceTests {
    @Test func rejectsSuggestionsFromAnotherAccountMissingMessagesAndDrafts() throws {
        for source in [
            AssistantSource(accountID: "other", threadID: "thread", messageID: "message", partID: nil, title: "Proposal"),
            AssistantSource(accountID: "account", threadID: "thread", messageID: "missing", partID: nil, title: "Proposal"),
        ] {
            let report = try report(source: source)
            #expect(FollowUpSuggestionRequest.make(report.summary.openTasks[0], report: report, detail: detail()) == nil)
        }
        let source = AssistantSource(accountID: "account", threadID: "thread", messageID: "message", partID: nil, title: "Proposal")
        let report = try report(source: source)
        #expect(FollowUpSuggestionRequest.make(report.summary.openTasks[0], report: report,
            detail: detail(labels: [SystemLabel.draft])) == nil)
    }

    @Test func acceptanceIdentityIgnoresCosmeticWhitespaceAndDeadlineUsesCanonicalDay() throws {
        let source = AssistantSource(accountID: "account", threadID: "thread", messageID: "message", partID: nil, title: "Proposal")
        let first = try report(source: source)
        let second = try report(source: source, title: "  Send  the proposal  ")
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let original = try #require(FollowUpSuggestionRequest.make(first.summary.openTasks[0], report: first,
            detail: detail()))
        let refreshed = try #require(FollowUpSuggestionRequest.make(second.summary.openTasks[0], report: second,
            detail: detail()))
        #expect(original.acceptanceKey == refreshed.acceptanceKey)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let due = try #require(original.dueAt)
        #expect(calendar.dateComponents([.year, .month, .day], from: due) == DateComponents(year: 2026, month: 11, day: 9))
        #expect(original.source.accountID == "account")
        #expect(original.source.messageID == "message")
    }

    private func report(source: AssistantSource, title: String = "Send the proposal") throws -> ThreadSummaryReport {
        let data = try JSONSerialization.data(withJSONObject: [
            "summary": "A proposal is due.", "source_ids": [source.id], "decisions": [],
            "open_tasks": [["description": title, "owner": "Alex", "due_date": "2026-11-09", "source_ids": [source.id]]],
        ])
        let summary = try AssistantSummary.decode(data, allowedSourceIDs: [source.id])
        return ThreadSummaryReport(summary: summary, sources: [source], hasPartialCoverage: false)
    }

    private func detail(labels: Set<String> = [SystemLabel.inbox]) -> ThreadDetail {
        let message = MessageRecord(accountID: "account", id: "message", threadID: "thread", historyID: 1,
            date: Date(timeIntervalSince1970: 1_790_000_000), snippet: "Please send a proposal.",
            sender: "Alex <alex@example.test>", recipients: "me@example.test", cc: nil, subject: "Proposal", sizeEstimate: 100)
        return ThreadDetail(thread: ThreadRecord(accountID: "account", id: "thread", lastDate: message.date,
            subject: message.subject, snippet: message.snippet, participants: message.sender, messageCount: 1,
            isUnread: false, isStarred: false), messages: [MessageDetail(record: message, labels: labels, body: nil)])
    }
}
