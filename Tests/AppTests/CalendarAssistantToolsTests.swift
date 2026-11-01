import Foundation
import GmailAPI
import MailStore
import SyncEngine
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct CalendarAssistantToolsTests {
    @Test func availabilityPermissionCannotReadDetails() async throws {
        let fixture = Fixture(access: .availability)
        await #expect(throws: CalendarAssistantTools.ToolError.self) {
            try await fixture.tools.execute(Self.call("read_calendar_event", [
                "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .string("e")
            ]))
        }
        #expect(fixture.readCount == 0)
        let list = try await fixture.tools.execute(Self.call("list_calendars", [:]))
        #expect(list.data["calendars"]?.arrayValue?.count == 1)
        #expect(list.sources.isEmpty)
    }

    @Test func identicalCalendarIDsRemainAccountScoped() async throws {
        let fixture = Fixture()
        await #expect(throws: CalendarAssistantTools.ToolError.self) {
            try await fixture.tools.execute(Self.call("read_calendar_event", [
                "account_id": .string("b"), "calendar_id": .string("work"), "event_id": .string("e")
            ]))
        }
        #expect(fixture.readCount == 0)
        let result = try await fixture.tools.execute(Self.call("read_calendar_event", [
            "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .string("e")
        ]))
        #expect(result.sources.first?.accountID == "a")
        #expect(result.sources.first?.isCalendar == true)
    }

    @Test func accessRevokedDuringReadDiscardsTheResult() async throws {
        let fixture = Fixture()
        fixture.revokeDuringRead = true
        await #expect(throws: CalendarAssistantTools.ToolError.self) {
            try await fixture.tools.execute(Self.call("read_calendar_event", [
                "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .string("e")
            ]))
        }
        #expect(fixture.readCount == 1)
    }

    @Test func aFailedCalendarProducesNoAvailableTimes() async throws {
        let fixture = Fixture(access: .availability)
        fixture.availabilityFails = true
        let result = try await fixture.tools.execute(Self.call("check_availability", Self.availabilityArguments))
        #expect(result.availabilityChoices.isEmpty)
        #expect(result.data["is_complete"] == .bool(false))
        #expect(fixture.readCount == 0)
        #expect(fixture.proposalCount == 0)
    }

    @Test func availableOptionsHaveNoEventDetailsOrSideEffects() async throws {
        let fixture = Fixture(access: .availability)
        let result = try await fixture.tools.execute(Self.call("check_availability", Self.availabilityArguments))
        #expect(!result.availabilityChoices.isEmpty)
        #expect(result.calendarProposals.isEmpty)
        #expect(result.sources.isEmpty)
        #expect(fixture.proposalCount == 0)
        #expect(fixture.readCount == 0)
        let encoded = try result.data.jsonString()
        #expect(!encoded.contains("Private appointment"))
        #expect(result.availabilityChoices.allSatisfy { $0.calendarKeys == [fixture.key] })
    }

    @Test func choosingAFormerlyFreeIntervalRequiresAFreshCheck() async throws {
        let fixture = Fixture(access: .availability)
        let initial = try await fixture.tools.execute(Self.call("check_availability", Self.availabilityArguments))
        let chosen = try #require(initial.availabilityChoices.first)
        fixture.newBusy = [.init(start: chosen.start, end: chosen.end)]
        let fresh = try await CalendarAssistantTools.check(keys: chosen.calendarKeys, start: chosen.start,
            end: chosen.end, hours: .init(timeZoneIdentifier: "UTC"), bindings: fixture.bindings, validate: {})
        #expect(fresh.isComplete)
        #expect(fresh.slots.isEmpty)
        #expect(fixture.proposalCount == 0)
    }

    @Test func aMissingCalendarResponseIsUnknownEvenWithoutAnAPIError() async throws {
        let fixture = Fixture(access: .availability)
        fixture.omitCalendar = true
        let result = try await fixture.tools.execute(Self.call("check_availability", Self.availabilityArguments))
        #expect(result.data["is_complete"] == .bool(false))
        #expect(result.availabilityChoices.isEmpty)
    }

    @Test(arguments: ["2030-01-11T19:07:00+01:00", "2030-01-13T15:07:00+01:00", "2030-01-11T23:07:00+01:00"])
    func requestedIntervalsIncludeDinnerWeekendsAndMidnight(startText: String) async throws {
        let fixture = Fixture(access: .availability)
        let start = try #require(CalendarAssistantTools.parseDate(startText))
        let arguments: [String: AIJSON] = ["calendars": .null, "start": .string(startText),
            "end": .string(CalendarAssistantTools.timestamp(start.addingTimeInterval(2 * 3600))),
            "time_zone": .string("Europe/Vienna")]
        let result = try await fixture.tools.execute(Self.call("check_requested_availability", arguments))
        #expect(result.data["is_complete"] == .bool(true))
        #expect(result.data["is_available"] == .bool(true))
        #expect(result.data["duration_minutes"] == .number(120))
        #expect(result.data["reserves_time"] == .bool(false))
        #expect(result.availabilityChoices.isEmpty)
        #expect(result.calendarProposals.isEmpty)
        #expect(result.sources.isEmpty)
        #expect(fixture.readCount == 0)
        #expect(fixture.proposalCount == 0)
        let workHours = try await fixture.tools.execute(Self.call("check_availability",
            arguments.merging(["duration_minutes": .number(120)]) { _, new in new }))
        #expect(workHours.availabilityChoices.isEmpty)
    }

    @Test func requestedIntervalDetectsOverlapButAllowsAdjacentAppointments() async throws {
        let fixture = Fixture(access: .availability)
        let start = try #require(CalendarAssistantTools.parseDate("2030-01-11T19:00:00Z"))
        let end = start.addingTimeInterval(2 * 3600)
        let arguments: [String: AIJSON] = ["calendars": .null, "start": .string(CalendarAssistantTools.timestamp(start)),
            "end": .string(CalendarAssistantTools.timestamp(end)), "time_zone": .string("UTC")]
        fixture.newBusy = [.init(start: start.addingTimeInterval(3600), end: end)]
        let busy = try await fixture.tools.execute(Self.call("check_requested_availability", arguments))
        #expect(busy.data["is_complete"] == .bool(true))
        #expect(busy.data["is_available"] == .bool(false))
        fixture.newBusy = [.init(start: start.addingTimeInterval(-3600), end: start),
                           .init(start: end, end: end.addingTimeInterval(3600))]
        let adjacent = try await fixture.tools.execute(Self.call("check_requested_availability", arguments))
        #expect(adjacent.data["is_available"] == .bool(true))
    }

    @Test(arguments: ["failure", "missing", "malformed"])
    func requestedIntervalNeverTreatsIncompleteBusyDataAsFree(problem: String) async throws {
        let fixture = Fixture(access: .availability)
        fixture.availabilityFails = problem == "failure"
        fixture.omitCalendar = problem == "missing"
        if problem == "malformed" { fixture.newBusy = [.init(start: "invalid", end: "invalid")] }
        var arguments = Self.availabilityArguments
        arguments.removeValue(forKey: "duration_minutes")
        let result = try await fixture.tools.execute(Self.call("check_requested_availability", arguments))
        #expect(result.data["is_complete"] == .bool(false))
        #expect(result.data["is_available"] == .null)
        #expect(result.data["failures"]?.objectValue?.isEmpty == false)
        #expect(result.availabilityChoices.isEmpty)
    }

    @Test func requestedIntervalRejectsRevokedAndUnpermittedCalendars() async throws {
        let fixture = Fixture(access: .availability)
        var arguments = Self.availabilityArguments
        arguments.removeValue(forKey: "duration_minutes")
        fixture.revokeDuringAvailability = true
        await #expect(throws: CalendarAssistantTools.ToolError.self) {
            try await fixture.tools.execute(Self.call("check_requested_availability", arguments))
        }
        let disabled = Fixture(access: .off)
        arguments["calendars"] = .array([.object(["account_id": .string("a"), "calendar_id": .string("work")])])
        await #expect(throws: CalendarAssistantTools.ToolError.self) {
            try await disabled.tools.execute(Self.call("check_requested_availability", arguments))
        }
    }

    @Test func proposalsAreIdempotentAndDoNotSaveEvents() async throws {
        let fixture = Fixture()
        let call = try Self.call("prepare_calendar_event", [
            "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .null,
            "title": .string("Planning"), "start": .string("2030-01-07T10:00:00Z"),
            "end": .string("2030-01-07T10:30:00Z"), "time_zone": .string("UTC"), "all_day": .bool(false),
            "location": .null, "notes": .null, "attendees": .null
        ], id: "proposal-1")
        let first = try await fixture.tools.execute(call)
        let second = try await fixture.tools.execute(call)
        #expect(fixture.proposalCount == 1)
        #expect(first.calendarProposals == second.calendarProposals)
        #expect(first.data["calendar_changed"] == .bool(false))
        #expect(first.data["invitations_sent"] == .bool(false))
        #expect(fixture.proposed?.summary == "Planning")
    }

    @Test func deletionPreparesOneReviewedProposalWithTheCurrentVersion() async throws {
        let fixture = Fixture()
        let call = try Self.call("prepare_calendar_deletion", [
            "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .string("e")
        ], id: "deletion-1")
        let first = try await fixture.tools.execute(call)
        let second = try await fixture.tools.execute(call)
        #expect(fixture.deletionProposalCount == 1)
        #expect(fixture.deletionProposal?.etag == "version-1")
        #expect(first.calendarProposals == second.calendarProposals)
        #expect(first.data["calendar_changed"] == .bool(false))
        #expect(first.data["invitations_sent"] == .bool(false))
    }

    @Test func availabilityOnlyAccessCannotPrepareDeletion() async throws {
        let fixture = Fixture(access: .availability)
        await #expect(throws: CalendarAssistantTools.ToolError.self) {
            try await fixture.tools.execute(Self.call("prepare_calendar_deletion", [
                "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .string("e")
            ]))
        }
        #expect(fixture.readCount == 0)
        #expect(fixture.deletionProposalCount == 0)
    }

    @Test func deletionWithoutAnEventVersionIsRejected() async throws {
        let fixture = Fixture()
        fixture.eventVersion = nil
        await #expect(throws: CalendarAssistantTools.ToolError.self) {
            try await fixture.tools.execute(Self.call("prepare_calendar_deletion", [
                "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .string("e")
            ]))
        }
        #expect(fixture.deletionProposalCount == 0)
    }

    @Test func calendarCitationsCannotMasqueradeAsMail() {
        let mail = AssistantSource(accountID: "a", threadID: "work", messageID: "e", partID: nil, title: "Mail")
        let event = AssistantSource(accountID: "a", calendarID: "work", eventID: "e", title: "Private appointment")
        var scope = AssistantScopeSnapshot(accountIDs: ["a"], threadIDs: nil, accountInstances: ["a": "1"], connectionRevision: 1, canUsePlan: true)
        #expect(scope.allows(mail))
        #expect(!scope.allows(event))
        scope.calendarScope = .init(access: [.init(accountID: "a", calendarID: "work"): .availability], revision: 1)
        #expect(!scope.allows(event))
        scope.calendarScope.access[.init(accountID: "a", calendarID: "work")] = .details
        #expect(scope.allows(event))
        #expect(mail.id != event.id)
    }

    @Test func editingTimesPreservesUnchangedNotesAndInvitees() async throws {
        let fixture = Fixture()
        let result = try await fixture.tools.execute(Self.call("prepare_calendar_event", [
            "account_id": .string("a"), "calendar_id": .string("work"), "event_id": .string("e"),
            "title": .string("Planning"), "start": .string("2030-01-07T10:00:00Z"),
            "end": .string("2030-01-07T10:30:00Z"), "time_zone": .string("UTC"), "all_day": .bool(false),
            "location": .null, "notes": .null, "attendees": .null
        ]))
        #expect(result.calendarProposals.count == 1)
        #expect(fixture.proposed?.description == "Existing notes")
        #expect(fixture.proposed?.attendees?.first?.email == "guest@example.invalid")
    }

    @Test func schedulingCombinesBusyTimeAcrossAccounts() async throws {
        let start = try #require(CalendarAssistantTools.parseDate("2030-01-07T09:00:00Z"))
        let end = start.addingTimeInterval(3 * 3600)
        let keys = [AssistantCalendarKey(accountID: "a", calendarID: "work"),
                    AssistantCalendarKey(accountID: "b", calendarID: "personal")]
        let bindings = CalendarAssistantBindings(calendars: { [] }, read: { _, _ in throw CalendarAssistantTools.ToolError.unknownEvent },
            query: { _, _, _ in .init(events: [], isStale: false, isComplete: true) },
            availability: { account, ids, _, _, hours in
                let offset = account == "a" ? 0.0 : 3600.0
                return .init(calendarIDs: ids, timeZone: hours.timeZoneIdentifier,
                    busy: [.init(start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 3600))], slots: [])
            }, prepare: { _, _, _ in UUID() }, workingHours: { .init(timeZoneIdentifier: "UTC") })
        let result = try await CalendarAssistantTools.check(keys: keys, start: start, end: end,
            hours: .init(timeZoneIdentifier: "UTC"), bindings: bindings, validate: {})
        #expect(result.isComplete)
        #expect(result.slots.first?.start == start.addingTimeInterval(2 * 3600))
        #expect(result.slots.allSatisfy { $0.start >= start.addingTimeInterval(2 * 3600) })
    }

    @Test func calendarOnlyChatWorksAndRevocationClearsIt() async throws {
        let state = CalendarContext()
        let app = AppModel()
        let model = AssistantModel(app: app, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
            provider: CalendarProvider(), context: { state.value },
            makeTools: { _ in AssistantToolSession(definitions: [], execute: { _ in .init(data: .null) }) })
        await model.refreshConnection()
        #expect(model.enabledAccountIDs.isEmpty)
        #expect(model.hasCalendarAccess)
        model.send("What is on my calendar?")
        await model.waitForCurrentTurn()
        #expect(model.messages.last?.state == .completed)
        state.access = [:]
        state.revision += 1
        model.refreshAccess()
        #expect(model.messages.isEmpty)
        #expect(!model.hasCalendarAccess)
    }

    @Test func emailExtractionStillRequiresMailPermission() async throws {
        let state = CalendarContext()
        let app = AppModel()
        let model = AssistantModel(app: app, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
            provider: CalendarProvider(), context: { state.value })
        await model.refreshConnection()
        #expect(model.hasCalendarAccess)
        #expect(throws: AssistantError.self) {
            try model.calendarExtractionService(for: .init(accountID: "a", threadID: "thread"))
        }
    }

    @Test func emailExtractionInvalidatesItsCapturedMailScope() async throws {
        let state = CalendarContext()
        state.includeMail = true
        let app = AppModel()
        let model = AssistantModel(app: app, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
            provider: CalendarProvider(), context: { state.value })
        model.setAccountEnabled("a", enabled: true)
        let initialRevision = model.calendarExtractionRevision
        await model.refreshConnection()
        #expect(model.calendarExtractionRevision > initialRevision)
        let service = try model.calendarExtractionService(for: .init(accountID: "a", threadID: "thread"))
        #expect(service.isScopeValid())
        let permittedRevision = model.calendarExtractionRevision
        model.setAccountEnabled("a", enabled: false)
        #expect(!service.isScopeValid())
        #expect(model.calendarExtractionRevision > permittedRevision)
    }

    private static var availabilityArguments: [String: AIJSON] {
        ["calendars": .null, "start": .string("2030-01-07T09:00:00Z"), "end": .string("2030-01-07T17:00:00Z"),
         "time_zone": .string("UTC"), "duration_minutes": .number(30)]
    }
    private static func call(_ name: String, _ arguments: [String: AIJSON], id: String = UUID().uuidString) throws -> AIToolCall {
        .init(id: id, namespace: "tern", name: name, arguments: try AIJSON.object(arguments).jsonString())
    }

    @MainActor private final class Fixture {
        let key = AssistantCalendarKey(accountID: "a", calendarID: "work")
        let access: CalendarAssistantAccess
        var valid = true
        var revokeDuringRead = false
        var revokeDuringAvailability = false
        var availabilityFails = false
        var omitCalendar = false
        var newBusy: [CalendarBusyInterval] = []
        var readCount = 0
        var proposalCount = 0
        var proposed: GoogleCalendarEvent?
        var deletionProposalCount = 0
        var deletionProposal: GoogleCalendarEvent?
        var eventVersion: String? = "version-1"
        lazy var tools = CalendarAssistantTools(scope: .init(access: [key: access], revision: 3), bindings: bindings, isScopeValid: { [weak self] in self?.valid == true })
        init(access: CalendarAssistantAccess = .details) { self.access = access }
        var bindings: CalendarAssistantBindings {
            .init(calendars: { [self] in [.init(key: key, title: "Work", canWrite: true, includeInScheduling: true)] },
                  read: { [self] _, eventID in
                      readCount += 1
                      if revokeDuringRead { valid = false }
                      var event = GoogleCalendarEvent(id: eventID, summary: "Private appointment")
                      event.etag = eventVersion
                      event.description = "Existing notes"
                      event.attendees = [.init(email: "guest@example.invalid")]
                      return event
                  },
                  query: { _, _, _ in .init(events: [], isStale: false, isComplete: true) },
                  availability: { [self] _, ids, start, end, hours in
                      if revokeDuringAvailability { valid = false }
                      return .init(calendarIDs: omitCalendar ? [] : ids, timeZone: hours.timeZoneIdentifier, busy: newBusy,
                            slots: [], failures: availabilityFails ? ["work": "Unavailable"] : [:])
                  },
                  prepare: { [self] _, event, _ in proposalCount += 1; proposed = event; return UUID() },
                  workingHours: { .init(timeZoneIdentifier: "UTC") },
                  prepareDeletion: { [self] _, event in
                      deletionProposalCount += 1; deletionProposal = event; return UUID()
                  })
        }
    }

    @MainActor private final class CalendarContext {
        var access: [AssistantCalendarKey: CalendarAssistantAccess] = [.init(accountID: "a", calendarID: "work"): .details]
        var revision = 1
        var includeMail = false
        var value: AssistantContext {
            .init(accounts: includeMail ? [.init(id: "a", email: "a@example.invalid", displayName: nil, grantedScopes: [], addedAt: .distantPast)] : [],
                isAccountListReady: true, currentAccountIDs: includeMail ? ["a"] : [],
                selectedThreads: includeMail ? [.init(accountID: "a", threadID: "thread")] : [], accountInstances: includeMail ? ["a": "1"] : [:],
                connectionRevision: 1, canUsePlan: true, calendarScope: .init(access: access, revision: revision))
        }
    }
    private struct CalendarProvider: AIProvider {
        func models() async throws -> [AIModel] { [.init(id: "test", displayName: "Test")] }
        func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.completed(.init(output: [], text: "Ready.", toolCalls: [])))
                continuation.finish()
            }
        }
    }
}
