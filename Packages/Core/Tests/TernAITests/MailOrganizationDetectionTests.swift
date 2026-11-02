import Foundation
import Testing
@testable import TernAI

@Suite struct MailOrganizationDetectionTests {
    @Test(arguments: ["personal", "singleThread", "sentToSender", "sentInThread", "mixedAutomation"])
    func correspondenceAndWeakRecurrenceKeepLabelsWithoutFutureRules(kind: String) async throws {
        var messages = [
            email("one", thread: "first", date: 10, mailingList: kind != "personal"),
            email("two", thread: kind == "singleThread" ? "first" : "second", date: 20,
                  mailingList: !["personal", "mixedAutomation"].contains(kind)),
        ]
        if kind == "sentToSender" || kind == "sentInThread" {
            messages.append(email("reply", thread: kind == "sentInThread" ? "first" : "separate", date: 30,
                sent: true, sender: "owner@example.invalid",
                recipients: [kind == "sentToSender" ? "sender@example.invalid" : "team@example.invalid"]))
        }
        let plan = try await analyze(messages, categories: [category("Work", ids: ["one", "two"], senders: ["sender@example.invalid"])],
                                     labels: ["Work"])
        #expect(plan.categories.count == 1)
        #expect(plan.categories.first?.messageIDs == ["two", "one"])
        #expect(plan.categories.first?.ruleSenders.isEmpty == true)
    }

    @Test(arguments: ["newSingleton", "existingSingleton", "repliesInOneThread", "twoThreads"])
    func newTopicsNeedIndependentExamplesAndExistingLabelsKeepTheirSpelling(kind: String) async throws {
        let existing = "Café Projects"
        let proposed = kind == "existingSingleton" ? "CAFE\u{0301} PROJECTS" : "Projects"
        var messages = [email("one", thread: "first", date: 10)]
        if kind == "repliesInOneThread" || kind == "twoThreads" {
            messages.append(email("two", thread: kind == "twoThreads" ? "second" : "first", date: 20))
        }
        let plan = try await analyze(messages, categories: [category(proposed, ids: messages.map(\.id))],
                                     labels: kind == "existingSingleton" ? [existing] : [])
        if kind == "existingSingleton" || kind == "twoThreads" {
            #expect(plan.categories.count == 1)
            #expect(plan.categories.first?.name == (kind == "existingSingleton" ? existing : proposed))
            #expect(Set(plan.categories.first?.messageIDs ?? []) == Set(messages.map(\.id)))
        } else {
            #expect(plan.categories.isEmpty)
        }
        #expect(plan.analyzedCount == messages.count)
    }

    @Test func tiedLatestDatesDoNotInventAnActionOrWaitingState() async throws {
        let recorder = OrganizationRequestRecorder()
        let messages = [email("incoming", thread: "conversation", date: 20),
                        email("sent", thread: "conversation", date: 20, sent: true, sender: "owner@example.invalid"),
                        email("invoice", thread: "invoice", date: 10)]
        let plan = try await analyze(messages, categories: [
            category("Action", kind: "action", ids: ["incoming"]),
            category("Waiting", kind: "waiting", ids: ["sent"]),
            category("Accounts & Finance", ids: ["invoice"]),
        ], labels: ["Accounts & Finance"], recorder: recorder)
        #expect(plan.categories.map(\.name) == ["Accounts & Finance"])
        let input = try await input(from: recorder)
        let entries = try #require(input["messages"]?.arrayValue)
        for id in ["incoming", "sent"] {
            #expect(entries.first { $0["id"] == .string(id) }?["latest_in_thread"] == .bool(false))
        }
    }

    @Test func sendsExactRelevantLabelsAndComputedEvidenceInOneRequest() async throws {
        let recorder = OrganizationRequestRecorder()
        let used = "Z " + String(repeating: "é", count: 75)
        let labels = (0..<600).map { "A unused \($0)" } + [used]
        let messages = [
            email("first", thread: "conversation", date: 10, labels: [used], mailingList: true),
            email("second", thread: "invoice", date: 20, labels: [used], automated: true,
                  snippet: String(repeating: "Invoice details. ", count: 100)),
            email("reply", thread: "conversation", date: 30, sent: true, sender: "owner@example.invalid",
                  recipients: ["sender@example.invalid"]),
        ]
        let plan = try await analyze(messages, categories: [category(used, ids: ["first", "second"])],
                                     labels: labels, recorder: recorder)
        #expect(plan.categories.first?.name == used)
        #expect(await recorder.requests.count == 1)
        let input = try await input(from: recorder)
        #expect(input["existing_labels"]?.arrayValue?.first == .string(used))
        let entries = try #require(input["messages"]?.arrayValue)
        let first = try #require(entries.first { $0["id"] == .string("first") })
        let second = try #require(entries.first { $0["id"] == .string("second") })
        #expect(first["labels"]?.arrayValue?.contains(.string(used)) == true)
        #expect(second["labels"]?.arrayValue?.contains(.string(used)) == true)
        #expect(first["mailing_list"] == .bool(true))
        #expect(first["automated"] == .bool(false))
        #expect(first["latest_in_thread"] == .bool(false))
        #expect(first["snippet_truncated"] == .bool(false))
        #expect(second["automated"] == .bool(true))
        #expect(second["latest_in_thread"] == .bool(true))
        #expect(second["snippet_truncated"] == .bool(true))
        let patterns = try #require(input["sender_patterns"]?.arrayValue)
        let sender = try #require(patterns.first { $0["sender"] == .string("sender@example.invalid") })
        #expect(sender["incoming_count"] == .number(2))
        #expect(sender["thread_count"] == .number(2))
        #expect(sender["mailing_list_count"] == .number(1))
        #expect(sender["automated_count"] == .number(1))
        #expect(sender["has_correspondence"] == .bool(true))
        #expect(sender["rule_eligible"] == .bool(false))
    }

    private func analyze(_ messages: [OrganizationEmail], categories: [AIJSON], labels: [String] = [],
                         recorder: OrganizationRequestRecorder = OrganizationRequestRecorder()) async throws -> OrganizationPlan {
        let response = AIResponse(output: [], text: try AIJSON.object(["categories": .array(categories)]).jsonString(), toolCalls: [])
        let provider = OrganizationProvider(events: [.completed(response)], recorder: recorder)
        return try await MailOrganizationAnalyzer(provider: provider).analyze(messages: messages, existingLabelNames: labels, model: "test")
    }

    private func input(from recorder: OrganizationRequestRecorder) async throws -> AIJSON {
        let request = try #require(await recorder.requests.first)
        let content = try #require(request.input.first?["content"]?.stringValue)
        return try AIJSON.decode(Data(content.utf8))
    }

    private func email(_ id: String, thread: String, date: TimeInterval, sent: Bool = false,
                       sender: String = "sender@example.invalid", recipients: [String] = ["owner@example.invalid"],
                       labels: [String] = [], mailingList: Bool = false, automated: Bool = false,
                       snippet: String = "Please review this message.") -> OrganizationEmail {
        OrganizationEmail(id: id, threadID: thread, sender: sender, recipients: recipients,
            subject: "Message", snippet: snippet, date: Date(timeIntervalSince1970: date), isSent: sent,
            labelNames: labels, hasMailingListHeaders: mailingList, isAutomated: automated)
    }

    private func category(_ name: String, kind: String = "topic", ids: [String], senders: [String] = []) -> AIJSON {
        .object(["name": .string(name), "explanation": .string("Messages about this topic."), "kind": .string(kind),
                 "message_ids": .array(ids.map(AIJSON.string)), "rule_senders": .array(senders.map(AIJSON.string))])
    }
}
