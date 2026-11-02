import Foundation
import GmailAPI
import MailStore
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct AssistantResultToolsTests {
    @Test func tasksRequireCompletedReadAndMatchingEvidence() throws {
        let tools = Self.tools()
        let source = Self.source()
        let read = Self.read(source)
        let request = try Self.taskCall(source)
        tools.register(read, from: try Self.call("search_mail", [:]))
        #expect(throws: AssistantResultTools.ToolError.self) { try tools.execute(request) }

        tools.register(read, from: try Self.call("read_thread", [:]))
        #expect(throws: AssistantResultTools.ToolError.self) {
            try tools.execute(Self.taskCall(Self.source(message: "unread")))
        }
        #expect(throws: AssistantResultTools.ToolError.self) {
            try tools.execute(Self.taskCall(source, evidence: "This sentence was never read."))
        }
        let result = try tools.execute(Self.taskCall(source, evidence: "Please send the proposal\nby Friday."))
        let task = try #require(result.taskResults.first)
        #expect(task.source == source)
        #expect(task.request.source?.accountID == "a")
        #expect(task.request.source?.messageID == "m")
        #expect(task.request.dueDate == "2026-11-06")
        #expect(task.request.notes.contains("From email:"))
        #expect(result.createdDraftID == nil)
        #expect(result.calendarProposals.isEmpty)
        #expect(result.data["saved"] == .bool(false))
    }

    @Test func registrationCannotWidenAccountOrThreadScope() throws {
        let tools = Self.tools(selectedThreads: [.init(accountID: "a", threadID: "t")])
        for source in [Self.source(account: "b"), Self.source(thread: "other")] {
            tools.register(Self.read(source), from: try Self.call("read_thread", [:]))
            #expect(throws: AssistantResultTools.ToolError.self) { try tools.execute(Self.taskCall(source)) }
        }
        let source = Self.source()
        var invalid = try #require(Self.read(source).data.objectValue)
        invalid["account_id"] = .string("b")
        tools.register(.init(data: .object(invalid), sources: [source]), from: try Self.call("read_thread", [:]))
        #expect(throws: AssistantResultTools.ToolError.self) { try tools.execute(Self.taskCall(source)) }
    }

    @Test(arguments: ["2026-02-30", "2026-11-06T00:00:00Z", "2026-1-06"])
    func taskDueDaysMustBeRealCivilDates(_ due: String) throws {
        let tools = Self.tools()
        let source = Self.source()
        tools.register(Self.read(source), from: try Self.call("read_thread", [:]))
        #expect(throws: AssistantResultTools.ToolError.self) { try tools.execute(Self.taskCall(source, due: due)) }
    }

    @Test func taskIdentitySurvivesDateAndSupportingMessageChanges() {
        let first = AssistantTaskResult(source: Self.source(), title: "Send  proposal", owner: "Alex",
                                        notes: "", dueDate: "2026-11-06", evidence: Self.evidence)
        let later = AssistantTaskResult(source: Self.source(message: "later"), title: "send proposal", owner: " alex ",
                                        notes: "Updated due date", dueDate: "2026-11-09", evidence: "Monday instead.")
        #expect(first.id == later.id)
        #expect(first.request.deduplicationKey == "suggestion\u{0}t\u{0}send proposal\u{0}alex")
        let other = AssistantTaskResult(source: Self.source(account: "b"), title: first.title, owner: first.owner,
                                        notes: "", dueDate: first.dueDate, evidence: first.evidence)
        #expect(first.id != other.id)
    }

    @Test func attachmentReadCanSupportTaskWithoutClaimingAnotherMessage() throws {
        let tools = Self.tools()
        let source = AssistantSource(accountID: "a", threadID: "t", messageID: "m", partID: "1", title: "Agenda.pdf")
        tools.register(.init(data: .object([
            "text": .string(Self.evidence), "source": .object(["source_id": .string(source.id)])
        ]), sources: [source]), from: try Self.call("read_attachment", [:]))
        let result = try tools.execute(Self.taskCall(source))
        #expect(result.taskResults.first?.source.partID == "1")
        #expect(throws: AssistantResultTools.ToolError.self) { try tools.execute(Self.taskCall(Self.source())) }
    }

    @Test func existingCalendarResultsKeepRetrievedMetadata() throws {
        let tools = Self.tools()
        let source = AssistantSource(accountID: "a", calendarID: "work", eventID: "event", title: "Original title")
        let row = AIJSON.object([
            "source_id": .string(source.id), "event_id": .string("event"), "title": .string("Original title"),
            "start": .string("2026-11-05T09:00:00Z"), "end": .string("2026-11-05T10:00:00Z"),
            "all_day": .bool(false), "time_zone": .string("Europe/Vienna"),
            "location": .string("Room 2"), "notes": .string("Original notes"), "notes_truncated": .bool(false)
        ])
        tools.register(.init(data: .object(["events": .array([row]), "is_stale": .bool(true)]), sources: [source]),
                       from: try Self.call("read_calendar_events", [:]))
        let result = try tools.execute(Self.eventCall(source, proposal: nil))
        let event = try #require(result.eventResults.first)
        #expect(event.source == source)
        #expect(event.event.id == "event")
        #expect(event.event.summary == "Original title")
        #expect(event.event.location == "Room 2")
        #expect(event.event.description == "Original notes")
        #expect(!event.uncertainties.isEmpty)
        #expect(result.calendarProposals.isEmpty)
        #expect(throws: AssistantResultTools.ToolError.self) {
            try tools.execute(Self.eventCall(source, proposal: Self.proposal()))
        }
        let noDetails = Self.tools(calendarDetails: false)
        noDetails.register(.init(data: row, sources: [source]), from: try Self.call("read_calendar_event", [:]))
        #expect(throws: AssistantResultTools.ToolError.self) { try noDetails.execute(Self.eventCall(source, proposal: nil)) }
    }

    @Test func mailEventsPreserveMissingDatesAndAllDayEndDates() throws {
        let tools = Self.tools()
        let source = Self.source()
        tools.register(Self.read(source), from: try Self.call("read_thread", [:]))
        var unknown = Self.proposal()
        unknown["start"] = .null
        unknown["end"] = .null
        let missing = try tools.execute(Self.eventCall(source, proposal: unknown))
        #expect(missing.eventResults.first?.event.start == nil)
        #expect(missing.eventResults.first?.event.end == nil)

        var allDay = Self.proposal()
        allDay["start"] = .string("2026-11-05")
        allDay["end"] = .string("2026-11-07")
        allDay["all_day"] = .bool(true)
        let result = try tools.execute(Self.eventCall(source, proposal: allDay))
        let event = try #require(result.eventResults.first?.event)
        #expect(event.start == CalendarDateTime(date: "2026-11-05"))
        #expect(event.end == CalendarDateTime(date: "2026-11-07"))
        #expect(event.attendees == nil)
    }

    @Test func mailEventsRejectAmbiguousOrInvalidDateValues() throws {
        let tools = Self.tools()
        let source = Self.source()
        tools.register(Self.read(source), from: try Self.call("read_thread", [:]))
        let edits: [(String, AIJSON)] = [
            ("start", .string("2026-11-05T09:00:00")),
            ("start", .string("2026-02-30T09:00:00Z")),
            ("start", .string("2026-11-05T25:00:00Z")),
            ("start", .string("2026-11-05")),
            ("end", .string("2026-11-05T08:00:00Z")),
            ("start", .null),
            ("time_zone", .string("Unrecognized/Zone"))
        ]
        for (key, value) in edits {
            var proposal = Self.proposal()
            proposal[key] = value
            #expect(throws: AssistantResultTools.ToolError.self) { try tools.execute(Self.eventCall(source, proposal: proposal)) }
        }
    }

    @Test func anUnstatedTimeZoneDoesNotPreventDisplayingAnEventCard() throws {
        let tools = Self.tools()
        let source = Self.source()
        let evidence = "Private sale on 3 November 2026, 12:00–23:00 online."
        tools.register(Self.read(source, text: evidence), from: try Self.call("read_thread", [:]))
        var proposal = Self.proposal()
        proposal["title"] = .string("Online private sale")
        proposal["start"] = .null
        proposal["end"] = .null
        proposal["evidence"] = .string(evidence)
        proposal["notes"] = .string("3 November 2026, 12:00–23:00")
        proposal["uncertainties"] = .array([.string("Time zone not stated; confirm before adding.")])

        let result = try tools.execute(Self.eventCall(source, proposal: proposal))
        let card = try #require(result.eventResults.first)
        #expect(card.event.description == "3 November 2026, 12:00–23:00")
        #expect(card.event.start == nil)
        #expect(!card.uncertainties.isEmpty)
        #expect(!card.canAddToCalendar)
        #expect(result.calendarProposals.isEmpty)
        #expect(result.data["saved"] == .bool(false))
    }

    @Test func presentationRejectsExtraFieldsAndBoundsTheResultList() throws {
        let tools = Self.tools()
        let source = Self.source()
        tools.register(Self.read(source), from: try Self.call("read_thread", [:]))
        var task = Self.task(source)
        task["account_id"] = .string("b")
        #expect(throws: AssistantResultTools.ToolError.self) {
            try tools.execute(Self.call("present_tasks", ["tasks": .array([.object(task)])]))
        }
        #expect(throws: AssistantResultTools.ToolError.self) {
            try tools.execute(Self.call("present_tasks", ["tasks": .array(Array(repeating: .object(Self.task(source)), count: 13))]))
        }
        let duplicate = try tools.execute(Self.call("present_tasks", ["tasks": .array([.object(Self.task(source)), .object(Self.task(source))])]))
        #expect(duplicate.taskResults.count == 1)
    }

    @Test func presentationAcceptsLargeValidBatchesWithinTheTransportLimit() throws {
        let tools = Self.tools()
        let source = Self.source()
        let evidence = String(String(repeating: "Please review the proposal. ", count: 40).prefix(1_000))
        tools.register(Self.read(source, text: evidence), from: try Self.call("read_thread", [:]))
        func request(notes: String) throws -> AIToolCall {
            let rows = (0..<12).map { index -> AIJSON in
                var fields = Self.task(source, evidence: evidence)
                fields["title"] = .string("Review proposal \(index)")
                fields["notes"] = .string(notes)
                return .object(fields)
            }
            return try Self.call("present_tasks", ["tasks": .array(rows)])
        }
        let accepted = try request(notes: String(repeating: "A", count: 2_000))
        #expect(accepted.arguments.utf8.count > 32_768)
        #expect(accepted.arguments.utf8.count <= AssistantResultTools.maximumArgumentBytes)
        let result = try tools.execute(accepted)
        #expect(result.taskResults.count == 12)
        #expect(result.data["saved"] == .bool(false))
        #expect(result.calendarProposals.isEmpty)

        // Each note still meets its character limit, but its UTF-8 representation
        // makes this complete batch too large for one provider tool call.
        let oversized = try request(notes: String(repeating: "📝", count: 2_000))
        #expect(oversized.arguments.utf8.count > AssistantResultTools.maximumArgumentBytes)
        #expect(throws: AssistantResultTools.ToolError.batchTooLarge) { try tools.execute(oversized) }
        let guidance = AssistantResultTools.ToolError.batchTooLarge.localizedDescription
        #expect(guidance.contains("65,536 UTF-8 bytes"))
        #expect(guidance.contains("smaller calls"))
    }

    private static let evidence = "Please send the proposal by Friday."

    private static func tools(selectedThreads: Set<ThreadKey>? = nil, calendarDetails: Bool = true) -> AssistantResultTools {
        AssistantResultTools(scope: .init(accountIDs: ["a"], threadIDs: selectedThreads,
            accountInstances: ["a": "instance"], connectionRevision: 1, canUsePlan: true,
            calendarScope: .init(access: [.init(accountID: "a", calendarID: "work"): calendarDetails ? .details : .availability])))
    }

    private static func source(account: String = "a", thread: String = "t", message: String = "m") -> AssistantSource {
        .init(accountID: account, threadID: thread, messageID: message, partID: nil, title: "Proposal")
    }

    private static func read(_ source: AssistantSource, text: String = evidence) -> AssistantToolResult {
        .init(data: .object([
            "account_id": .string(source.accountID), "thread_id": .string(source.threadID),
            "messages": .array([.object(["message_id": .string(source.messageID ?? ""),
                                         "thread_id": .string(source.threadID), "text": .string(text)])])
        ]), sources: [source])
    }

    private static func task(_ source: AssistantSource, evidence: String = evidence, due: String = "2026-11-06") -> [String: AIJSON] {
        ["source_id": .string(source.id), "title": .string("Send proposal"), "owner": .null,
         "notes": .null, "due_date": .string(due), "evidence": .string(evidence)]
    }

    private static func taskCall(_ source: AssistantSource, evidence: String = evidence, due: String = "2026-11-06") throws -> AIToolCall {
        try call("present_tasks", ["tasks": .array([.object(task(source, evidence: evidence, due: due))])])
    }

    private static func proposal() -> [String: AIJSON] {
        ["title": .string("Proposal review"), "start": .string("2026-11-05T09:00:00Z"),
         "end": .string("2026-11-05T10:00:00Z"), "all_day": .bool(false), "time_zone": .null,
         "location": .null, "notes": .null, "evidence": .string(evidence), "uncertainties": .array([])]
    }

    private static func eventCall(_ source: AssistantSource, proposal: [String: AIJSON]?) throws -> AIToolCall {
        try call("present_events", ["events": .array([.object([
            "source_id": .string(source.id), "proposal": proposal.map(AIJSON.object) ?? .null
        ])])])
    }

    private static func call(_ name: String, _ arguments: [String: AIJSON]) throws -> AIToolCall {
        .init(id: UUID().uuidString, namespace: "tern", name: name, arguments: try AIJSON.object(arguments).jsonString())
    }
}
