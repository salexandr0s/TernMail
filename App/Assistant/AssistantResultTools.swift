import Foundation
import GmailAPI
import TernAI

/// Presentation uses completed reads from one immutable scope. It never saves
/// tasks or calendar events; those actions belong to the user's review controls.
@MainActor
final class AssistantResultTools {
    enum ToolError: Error, LocalizedError, Equatable {
        case invalidArguments, batchTooLarge, invalidEventDates, unreadSource, unsupportedEvidence

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "The result has missing or invalid fields. Check its dates and source details."
            case .batchTooLarge: "This presentation exceeds 65,536 UTF-8 bytes across all arguments. Split it into smaller calls, with fewer results or shorter notes and excerpts. Earlier displayed cards are retained."
            case .invalidEventDates: "Use real YYYY-MM-DD dates for all-day events, or RFC3339 timestamps with seconds and explicit offsets for timed events. The end must follow the start. Use an IANA time zone or null. If the date is unknown, or a timed event's time zone is unknown, set both start and end to null and preserve the stated date and time in notes and uncertainties. Retry the affected events with present_events."
            case .unreadSource: "Read the supporting email or calendar event before displaying this result."
            case .unsupportedEvidence: "The supporting excerpt must come from the email or attachment that was read."
            }
        }
    }

    private struct ReadMail {
        let source: AssistantSource
        let text: String
    }

    private let scope: AssistantScopeSnapshot
    private var mail: [String: ReadMail] = [:]
    private var events: [String: AssistantEventResult] = [:]
    private var storedCharacters = 0
    static let maximumArgumentBytes = 65_536
    static let toolNames: Set<String> = ["present_tasks", "present_events"]
    private static let taskFields: Set<String> = ["source_id", "title", "owner", "notes", "due_date", "evidence"]
    private static let proposalFields: Set<String> = ["title", "start", "end", "all_day", "time_zone", "location", "notes", "evidence", "uncertainties"]

    init(scope: AssistantScopeSnapshot) { self.scope = scope }

    func register(_ result: AssistantToolResult, from call: AIToolCall) {
        guard call.namespace == "tern" else { return }
        switch call.name {
        case "read_thread":
            let rows = result.data["messages"]?.arrayValue ?? []
            for source in result.sources where scope.allows(source) && !source.isCalendar && source.partID == nil {
                guard let messageID = source.messageID,
                      source.accountID == result.data["account_id"]?.stringValue,
                      source.threadID == result.data["thread_id"]?.stringValue,
                      let row = rows.first(where: { $0["message_id"]?.stringValue == messageID }),
                      row["thread_id"]?.stringValue == source.threadID,
                      let text = row["text"]?.stringValue else { continue }
                registerMail(source, text: text)
            }
        case "read_attachment":
            guard let text = result.data["text"]?.stringValue,
                  let source = result.sources.first(where: { $0.id == result.data["source"]?["source_id"]?.stringValue }),
                  scope.allows(source), !source.isCalendar, source.messageID != nil else { return }
            registerMail(source, text: text)
        case "read_calendar_events", "read_calendar_event":
            let rows = call.name == "read_calendar_events" ? result.data["events"]?.arrayValue ?? [] : [result.data]
            for source in result.sources where source.isCalendar && scope.allows(source) {
                guard events.count < 500 || events[source.id] != nil,
                      let row = rows.first(where: { $0["source_id"]?.stringValue == source.id }),
                      case .calendar(_, let eventID) = source.target,
                      row["event_id"]?.stringValue == eventID,
                      let event = try? Self.calendarEvent(row, id: eventID) else { continue }
                var uncertainties = row["notes_truncated"] == .bool(true) ? ["Event notes were shortened."] : []
                if result.data["is_stale"] == .bool(true) { uncertainties.append("Calendar details may be out of date.") }
                events[source.id] = AssistantEventResult(source: source, event: event, evidence: nil, uncertainties: uncertainties)
            }
        default: break
        }
    }

    func execute(_ call: AIToolCall) throws -> AssistantToolResult {
        guard call.namespace == "tern", !call.id.isEmpty, Self.toolNames.contains(call.name) else { throw ToolError.invalidArguments }
        guard call.arguments.utf8.count <= Self.maximumArgumentBytes else { throw ToolError.batchTooLarge }
        guard let args = try AIJSON.decode(Data(call.arguments.utf8)).objectValue else { throw ToolError.invalidArguments }
        if call.name == "present_tasks" { return try presentTasks(args) }
        return try presentEvents(args)
    }

    private func registerMail(_ source: AssistantSource, text: String) {
        let normalized = Self.normalizeWhitespace(text)
        let newCount = storedCharacters - (mail[source.id]?.text.count ?? 0) + normalized.count
        guard (mail.count < 500 || mail[source.id] != nil), newCount <= 1_000_000 else { return }
        mail[source.id] = ReadMail(source: source, text: normalized)
        storedCharacters = newCount
    }

    private func presentTasks(_ args: [String: AIJSON]) throws -> AssistantToolResult {
        let rows = try Self.rows(args, name: "tasks")
        var tasks: [AssistantTaskResult] = []
        var seen = Set<String>()
        for row in rows {
            guard let fields = row.objectValue, Set(fields.keys) == Self.taskFields else { throw ToolError.invalidArguments }
            let sourceID = try Self.string(fields, "source_id", limit: 2_048)
            let evidence = try Self.string(fields, "evidence", limit: 1_000)
            let source = try mailSource(sourceID, evidence: evidence)
            let due = try Self.optionalString(fields, "due_date", limit: 10)
            if let due { guard Self.isDay(due) else { throw ToolError.invalidArguments } }
            let task = AssistantTaskResult(source: source,
                title: try Self.string(fields, "title", limit: 240),
                owner: try Self.optionalString(fields, "owner", limit: 240),
                notes: try Self.optionalString(fields, "notes", limit: 2_000) ?? "",
                dueDate: due, evidence: evidence)
            if seen.insert(task.id).inserted { tasks.append(task) }
        }
        return AssistantToolResult(data: Self.presented("task", count: tasks.count), sources: tasks.map(\.source), taskResults: tasks)
    }

    private func presentEvents(_ args: [String: AIJSON]) throws -> AssistantToolResult {
        let rows = try Self.rows(args, name: "events")
        var results: [AssistantEventResult] = []
        var seen = Set<String>()
        for row in rows {
            guard let fields = row.objectValue, Set(fields.keys) == ["source_id", "proposal"] else { throw ToolError.invalidArguments }
            let sourceID = try Self.string(fields, "source_id", limit: 2_048)
            let result: AssistantEventResult
            if let existing = events[sourceID] {
                guard fields["proposal"] == .null else { throw ToolError.invalidArguments }
                result = existing
            } else {
                guard let proposal = fields["proposal"]?.objectValue,
                      Set(proposal.keys) == Self.proposalFields else { throw ToolError.invalidArguments }
                let evidence = try Self.string(proposal, "evidence", limit: 1_000)
                let source = try mailSource(sourceID, evidence: evidence)
                var event = try Self.calendarEvent(.object(proposal), id: "")
                event.summary = try Self.string(proposal, "title", limit: 240)
                guard let uncertaintyValues = proposal["uncertainties"]?.arrayValue, uncertaintyValues.count <= 5 else {
                    throw ToolError.invalidArguments
                }
                let uncertainties = try uncertaintyValues.map { value -> String in
                    guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          text.count <= 280 else { throw ToolError.invalidArguments }
                    return text
                }
                result = AssistantEventResult(source: source, event: event, evidence: evidence, uncertainties: uncertainties)
            }
            if seen.insert(result.id).inserted { results.append(result) }
        }
        return AssistantToolResult(data: Self.presented("event", count: results.count), sources: results.map(\.source), eventResults: results)
    }

    private func mailSource(_ id: String, evidence: String) throws -> AssistantSource {
        guard let read = mail[id], scope.allows(read.source) else { throw ToolError.unreadSource }
        guard read.text.contains(Self.normalizeWhitespace(evidence)) else { throw ToolError.unsupportedEvidence }
        return read.source
    }

    private static func calendarEvent(_ row: AIJSON, id: String) throws -> GoogleCalendarEvent {
        guard let fields = row.objectValue, let allDay = fields["all_day"]?.boolValue else { throw ToolError.invalidArguments }
        let start = try optionalString(fields, "start", limit: 64)
        let end = try optionalString(fields, "end", limit: 64)
        let zone = try optionalString(fields, "time_zone", limit: 128)
        if let zone { guard TimeZone(identifier: zone) != nil else { throw ToolError.invalidEventDates } }
        guard start != nil || end == nil else { throw ToolError.invalidEventDates }
        let startValue = try start.map { try dateValue($0, allDay: allDay, zone: zone) }
        let endValue = try end.map { try dateValue($0, allDay: allDay, zone: zone) }
        if let start, let end {
            if allDay { guard end > start else { throw ToolError.invalidEventDates } }
            else {
                guard let first = CalendarDateCoding.date(start), let last = CalendarDateCoding.date(end), last > first else {
                    throw ToolError.invalidEventDates
                }
            }
        }
        var event = GoogleCalendarEvent(id: id, summary: try optionalString(fields, "title", limit: 1_024, allowsEmpty: true),
                                        start: startValue, end: endValue)
        event.location = try optionalString(fields, "location", limit: 2_048, allowsEmpty: true)
        event.description = try optionalString(fields, "notes", limit: 8_192, allowsEmpty: true)
        return event
    }

    private static func dateValue(_ value: String, allDay: Bool, zone: String?) throws -> CalendarDateTime {
        if allDay {
            guard isDay(value) else { throw ToolError.invalidEventDates }
            return CalendarDateTime(date: value)
        }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                          options: .regularExpression) != nil,
              isDay(String(value.prefix(10))),
              let hour = Int(value.dropFirst(11).prefix(2)), (0...23).contains(hour),
              let minute = Int(value.dropFirst(14).prefix(2)), (0...59).contains(minute),
              let second = Int(value.dropFirst(17).prefix(2)), (0...59).contains(second),
              CalendarDateCoding.date(value) != nil else { throw ToolError.invalidEventDates }
        return CalendarDateTime(dateTime: value, timeZone: zone)
    }

    private static func isDay(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            && GoogleTaskDateCoding.day(value) == value
    }

    private static func rows(_ args: [String: AIJSON], name: String) throws -> [AIJSON] {
        guard Set(args.keys) == [name], let rows = args[name]?.arrayValue, (1...12).contains(rows.count) else {
            throw ToolError.invalidArguments
        }
        return rows
    }

    private static func string(_ args: [String: AIJSON], _ key: String, limit: Int) throws -> String {
        guard let text = args[key]?.stringValue, text.count <= limit,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalidArguments }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalString(_ args: [String: AIJSON], _ key: String, limit: Int, allowsEmpty: Bool = false) throws -> String? {
        if args[key] == .null { return nil }
        guard let text = args[key]?.stringValue, text.count <= limit else { throw ToolError.invalidArguments }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsEmpty || !trimmed.isEmpty else { throw ToolError.invalidArguments }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func presented(_ kind: String, count: Int) -> AIJSON {
        .object(["status": .string("The \(kind) cards are displayed with source links and review actions. Nothing was added or saved. Do not repeat the cards as a text list."),
                 "count": .number(Double(count)), "saved": .bool(false)])
    }

    static var definitions: [AIToolDefinition] {
        func text(_ description: String, limit: Int, nullable: Bool = false) -> AIJSON {
            .object(["type": nullable ? .array([.string("string"), .string("null")]) : .string("string"),
                     "description": .string(description), "maxLength": .number(Double(limit))])
        }
        func object(_ properties: [String: AIJSON], nullable: Bool = false) -> AIJSON {
            .object(["type": nullable ? .array([.string("object"), .string("null")]) : .string("object"),
                     "properties": .object(properties), "required": .array(properties.keys.sorted().map(AIJSON.string)),
                     "additionalProperties": .bool(false)])
        }
        func array(_ item: AIJSON) -> AIJSON {
            .object(["type": .string("array"), "items": item, "minItems": .number(1), "maxItems": .number(12)])
        }
        let source = text("Exact source_id from a completed read in this chat. Search-only results cannot support extracted tasks or events.", limit: 2_048)
        let evidence = text("An exact supporting excerpt from the read message or attachment text; whitespace may be normalized.", limit: 1_000)
        let proposal = object([
            "title": text("Short event title supported by the source.", limit: 240),
            "start": text("Known start: YYYY-MM-DD for all-day, or RFC3339 with seconds and explicit offset for timed events. If the date is unknown, or a timed event's time zone is unknown, set start and end null; preserve stated local dates and times in notes and uncertainties so the card still displays them. Never guess an offset.", limit: 64, nullable: true),
            "end": text("Known exclusive end in the same format as start; null when duration is unknown.", limit: 64, nullable: true),
            "all_day": .object(["type": .string("boolean"), "description": .string("True only for an all-day event, not a timed event whose time is missing.")]),
            "time_zone": text("IANA time zone if known, otherwise null. Timed dates still require explicit offsets.", limit: 128, nullable: true),
            "location": text("Location from the source, or null.", limit: 2_048, nullable: true),
            "notes": text("Relevant event details from the source, or null. Do not include attendees or invitation actions.", limit: 8_192, nullable: true),
            "evidence": evidence,
            "uncertainties": .object(["type": .string("array"), "maxItems": .number(5),
                "items": text("A missing or ambiguous detail the user should review.", limit: 280)])
        ], nullable: true)
        return [
            .init(name: "present_tasks", description: "Display open tasks extracted from emails as task cards with due dates, evidence and Add to Tasks review controls. Read supporting messages first and check later replies for completion. Include tasks assigned to the user; identify another owner only when relevant to the request. Keep each call's complete arguments within 65,536 UTF-8 bytes; split larger batches into smaller calls. Earlier cards are retained and matching tasks are updated. This tool does not save tasks.", parameters: object([
                "tasks": array(object([
                    "source_id": source, "title": text("Concrete action to take.", limit: 240),
                    "owner": text("Named person responsible, or null when unstated.", limit: 240, nullable: true),
                    "notes": text("Useful context for completing the task, or null.", limit: 2_000, nullable: true),
                    "due_date": text("Explicit or unambiguously resolved due day as YYYY-MM-DD; null when absent or uncertain.", limit: 10, nullable: true),
                    "evidence": evidence
                ]))
            ])),
            .init(name: "present_events", description: "Display a readable agenda of events from mail or calendars. Existing calendar events require proposal:null and use their retrieved metadata. Mail events require a proposal supported by an exact excerpt. Keep unknown dates null and describe uncertainty. Do not invent attendees or treat a listing request as permission to book. Keep each call's complete arguments within 65,536 UTF-8 bytes; split larger batches into smaller calls. Earlier cards are retained and matching events are updated. Cards provide user review actions; this tool saves nothing.", parameters: object([
                "events": array(object(["source_id": source, "proposal": proposal]))
            ]))
        ]
    }
}
