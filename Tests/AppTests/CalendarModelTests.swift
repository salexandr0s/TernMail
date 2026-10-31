import Foundation
import GmailAPI
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct CalendarModelTests {
    @Test func calendarErrorsSeparateConsentFromCloudSetupAndHideProviderDetails() {
        let disabled = CalendarConnectionIssue(error: GmailError.http(status: 403, reason: "SERVICE_DISABLED"))
        let permission = CalendarConnectionIssue(error: GmailError.http(status: 403, reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT"))
        #expect(disabled == .apiDisabled)
        #expect(permission == .permissionDenied)
        #expect(!CalendarConnectionState(isEnabled: true, issue: disabled).needsAuthorization)
        #expect(CalendarConnectionState(isEnabled: true, issue: permission).needsAuthorization)
        let privateReason = "unexpected-private-provider-detail"
        let unknown = CalendarConnectionIssue(error: GmailError.http(status: 403, reason: privateReason))
        #expect(unknown == .unavailable)
        #expect(!unknown.message.contains(privateReason))
    }

    @Test func emptyCalendarCacheDoesNotLoseConnectionAndRemovalClearsIt() async throws {
        try await withFixture { fixture in
            fixture.model.calendars = []
            fixture.model.connectionStates[fixture.accountID] = CalendarConnectionState(isEnabled: true, issue: .network)
            #expect(!fixture.model.connectionState(for: fixture.accountID).needsAuthorization)

            fixture.model.accessExpired(fixture.accountID)
            #expect(fixture.model.connectionState(for: fixture.accountID).needsAuthorization)
            #expect(fixture.model.connectionState(for: fixture.accountID).issue == .signInRequired)

            await fixture.model.removeAccount(fixture.accountID)
            #expect(!fixture.model.connectionState(for: fixture.accountID).isEnabled)
            #expect(fixture.model.connectionState(for: fixture.accountID).issue == nil)
        }
    }

    @Test func duplicateOfflineSavesCloseTheEditorAndRetryOneDurableOperation() async throws {
        try await withFixture { fixture in
            await fixture.service.setOffline(true)
            let draft = CalendarEditorDraft(event: Self.event(), calendarKey: fixture.owner.id)
            fixture.model.editor = draft

            try await fixture.model.save(draft)

            #expect(fixture.model.editor == nil)
            try await fixture.model.save(draft)
            let queued = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(queued.count == 1)
            #expect(queued.first?.status == .queued)
            #expect(queued.first?.attempts == 0)
            #expect(await fixture.service.insertCount == 0)

            await fixture.service.setOffline(false)
            try await fixture.engine.flush()
            try await fixture.engine.flush()
            let completed = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(completed.count == 1)
            #expect(completed.first?.id == queued.first?.id)
            #expect(completed.first?.status == .completed)
            #expect(await fixture.service.insertCount == 1)
        }
    }

    @Test func savingAnAssistantProposalReplacesItsProposedOperation() async throws {
        try await withFixture { fixture in
            let id = fixture.model.prepare(event: Self.event(), accountID: fixture.accountID, calendarID: "work")
            await fixture.model.proposalTasks[id]?.value
            let draft = try #require(fixture.model.proposedEditors[id])
            let proposalID = try #require(draft.operationID)
            fixture.model.editor = draft
            await fixture.service.setOffline(true)

            try await fixture.model.save(draft)

            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(operations.first(where: { $0.id == proposalID })?.status == .cancelled)
            #expect(operations.filter { $0.status == .queued }.count == 1)
            #expect(!operations.contains { $0.status == .proposed })
            #expect(fixture.model.proposedEditors[id] == nil)
            #expect(fixture.model.editor == nil)

            await fixture.service.setOffline(false)
            try await fixture.engine.flush()
            try await fixture.engine.flush()
            #expect(await fixture.service.insertCount == 1)
        }
    }

    @Test(arguments: [false, true])
    func revokingAssistantAccessDiscardsPendingAndPersistedProposals(persistFirst: Bool) async throws {
        try await withFixture { fixture in
            let id = fixture.model.prepare(event: Self.event(), accountID: fixture.accountID, calendarID: "work")
            if persistFirst {
                await fixture.model.proposalTasks[id]?.value
                let draft = try #require(fixture.model.proposedEditors[id])
                fixture.model.editor = draft
                #expect(try await fixture.store.operations(accountID: fixture.accountID).first?.status == .proposed)
            }

            fixture.model.setAssistantAccess(id: fixture.owner.id, access: .off)
            for task in Array(fixture.model.proposalTasks.values) { await task.value }

            #expect(fixture.model.proposedEditors.isEmpty)
            #expect(fixture.model.editor == nil)
            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(operations.allSatisfy { $0.status == .cancelled })
            if persistFirst { #expect(operations.count == 1) }
            #expect(await fixture.service.insertCount == 0)
            #expect(await fixture.service.patchETags.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func revokingAssistantAccessCancelsAStoredProposalBeforeOrAfterActivityLoads(activityLoaded: Bool) async throws {
        try await withFixture { fixture in
            let operation = try await fixture.engine.propose(.create(Self.event()), calendarID: "work")
            var draft = CalendarEditorDraft(event: Self.event(), calendarKey: fixture.owner.id)
            draft.operationID = operation.id
            fixture.model.editor = draft
            if activityLoaded {
                await fixture.model.reloadOperations()
                #expect(fixture.model.proposedEditors.isEmpty)
            } else {
                fixture.model.proposedEditors[draft.id] = draft
                #expect(fixture.model.operations.isEmpty)
            }

            fixture.model.setAssistantAccess(id: fixture.owner.id, access: .off)
            for task in Array(fixture.model.proposalTasks.values) { await task.value }

            #expect(fixture.model.editor == nil)
            #expect(try await fixture.store.operations(accountID: fixture.accountID).first?.status == .cancelled)
            #expect(await fixture.service.insertCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func undoUsesTheSavedVersionAndRejectsLaterExternalEdits(externalEdit: Bool) async throws {
        try await withFixture { fixture in
            let original = Self.event(id: "event")
            await fixture.service.put(original)
            var edited = original
            edited.summary = "Changed in Tern"
            let source = fixture.display(original)
            let draft = CalendarEditorDraft(event: edited, calendarKey: fixture.owner.id, source: source)
            fixture.model.editor = draft
            try await fixture.model.save(draft)
            let operation = try #require(fixture.model.operations.first)
            let saved = try #require(operation.resultEvent)
            #expect(saved.etag == "remote-1")

            if externalEdit {
                var newer = saved
                newer.summary = "Changed elsewhere"; newer.etag = "external-version"
                await fixture.service.put(newer)
            }
            await fixture.model.undo()

            let remote = try await fixture.service.event(calendarID: "work", eventID: "event")
            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            let inverse = try #require(operations.first { $0.id != operation.id })
            guard case .update(_, _, let reviewedETag) = inverse.mutation else {
                Issue.record("Undo must enqueue an event update."); return
            }
            #expect(reviewedETag == saved.etag)
            if externalEdit {
                #expect(inverse.status == .conflicted)
                #expect(remote.summary == "Changed elsewhere")
                #expect(await fixture.service.patchETags == ["v1"])
            } else {
                #expect(inverse.status == .completed)
                #expect(remote.summary == original.summary)
                #expect(await fixture.service.patchETags == ["v1", "remote-1"])
            }
        }
    }

    @Test func overlappingUndoRequestsEnqueueOnlyOneInverse() async throws {
        try await withFixture { fixture in
            let original = Self.event(id: "event")
            await fixture.service.put(original)
            var edited = original
            edited.summary = "Changed in Tern"
            try await fixture.model.save(CalendarEditorDraft(event: edited, calendarKey: fixture.owner.id,
                source: fixture.display(original)))
            let undo = Task { await fixture.model.undo() }
            let confirmation = Task { await fixture.model.confirmUndo() }
            await undo.value
            await confirmation.value

            let operations = try await fixture.store.operations(accountID: fixture.accountID)
            #expect(operations.count == 2)
            #expect(operations.allSatisfy { $0.status == .completed })
            #expect(await fixture.service.patchETags == ["v1", "remote-1"])
            #expect(try await fixture.service.event(calendarID: "work", eventID: "event").summary == original.summary)
            #expect(fixture.model.undoActions.isEmpty)
            #expect(!fixture.model.isUndoing)
        }
    }

    @Test func movingAnAllDayEventAcrossAutumnDSTPreservesItsTwoCivilDays() async throws {
        try await withFixture { fixture in
            var original = Self.event(id: "trip")
            original.start = CalendarDateTime(date: "2026-11-02")
            original.end = CalendarDateTime(date: "2026-11-04")
            await fixture.service.put(original)
            let destination = try #require(fixture.model.calendar.date(from: DateComponents(year: 2026, month: 10, day: 24)))

            try await fixture.model.move(fixture.display(original), to: destination)

            let saved = try await fixture.service.event(calendarID: "work", eventID: "trip")
            #expect(saved.start?.date == "2026-10-24")
            #expect(saved.end?.date == "2026-10-26")
            let display = fixture.display(saved)
            #expect(display.end.timeIntervalSince(display.start) == 49 * 3600)
        }
    }

    @Test func aSeriesEditKeepsTheVersionReviewedInTheEditor() async throws {
        try await withFixture { fixture in
            var master = Self.event(id: "series")
            master.recurrence = ["RRULE:FREQ=WEEKLY"]
            var occurrence = master
            occurrence.id = "occurrence"
            occurrence.etag = "occurrence-version"
            occurrence.recurringEventId = master.id
            occurrence.originalStartTime = occurrence.start
            var draft = CalendarEditorDraft(event: occurrence, calendarKey: fixture.owner.id,
                source: fixture.display(occurrence), editScope: .series)
            draft.seriesMaster = master
            draft.event.summary = "Reviewed change"
            fixture.model.editor = draft
            var newer = master
            newer.etag = "external-version"; newer.summary = "Concurrent change"
            await fixture.service.put(newer)

            try await fixture.model.save(draft)

            let operation = try #require(try await fixture.store.operations(accountID: fixture.accountID).first)
            guard case .update(let eventID, _, let etag) = operation.mutation else {
                Issue.record("Editing all events must update the series master."); return
            }
            #expect(eventID == master.id)
            #expect(etag == master.etag)
            #expect(operation.status == .conflicted)
            #expect(await fixture.service.patchETags.isEmpty)
            #expect(try await fixture.service.event(calendarID: "work", eventID: master.id).summary == "Concurrent change")
        }
    }

    private static func event(id: String = "") -> GoogleCalendarEvent {
        var event = GoogleCalendarEvent(id: id, summary: "Planning",
            start: CalendarDateTime(dateTime: "2030-01-07T10:00:00+01:00", timeZone: "Europe/Vienna"),
            end: CalendarDateTime(dateTime: "2030-01-07T11:00:00+01:00", timeZone: "Europe/Vienna"))
        event.etag = "v1"
        return event
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @MainActor private final class Fixture {
        let accountID = "calendar-model-test-" + UUID().uuidString
        let defaultsName = "CalendarModelTests." + UUID().uuidString
        let defaults: UserDefaults
        let model: CalendarModel
        let store: CalendarStore
        let service = ModelCalendarService()
        let engine: CalendarSyncEngine
        let owner: CalendarDisplayCalendar

        init() async throws {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            store = try CalendarStore.inMemory()
            engine = CalendarSyncEngine(accountID: accountID, service: service, store: store)
            owner = CalendarDisplayCalendar(entry: ModelCalendarService.entry, accountID: accountID,
                accountName: "Synthetic account", aiAccess: .details)
            model = CalendarModel(app: nil, defaults: defaults)
            model.store = store
            model.engines = [accountID: engine]
            model.calendars = [owner]
            model.workingHours = CalendarWorkingHours(timeZoneIdentifier: "Europe/Vienna")
            let preference = CalendarPreferences(accountID: accountID, calendarID: "work", assistantAccess: .details,
                notificationsEnabled: false)
            model.preferences = [owner.id: preference]
            try await store.replaceCalendars([ModelCalendarService.entry], accountID: accountID)
            try await store.savePreferences(preference)
        }

        func display(_ event: GoogleCalendarEvent) -> CalendarDisplayEvent {
            CalendarDisplayEvent(event: event, accountID: accountID, calendarID: "work", fallbackTimeZoneID: "Europe/Vienna")
        }

        func close() async {
            await model.stop()
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private actor ModelCalendarService: CalendarService {
        static let entry = GoogleCalendarEntry(id: "work", summary: "Work", timeZone: "Europe/Vienna", accessRole: "owner")
        private var remote: [String: GoogleCalendarEvent] = [:]
        private var offline = false
        private(set) var insertCount = 0
        private(set) var patchETags: [String?] = []

        func setOffline(_ value: Bool) { offline = value }
        func put(_ event: GoogleCalendarEvent) { remote[event.id] = event }

        func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage {
            if offline { throw GmailError.transport(.notConnectedToInternet) }
            return CalendarListPage(items: [Self.entry])
        }

        func events(calendarID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
            if offline { throw GmailError.transport(.notConnectedToInternet) }
            return CalendarEventPage(items: Array(remote.values), nextSyncToken: "snapshot")
        }

        func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
            guard let event = remote[eventID] else { throw GmailError.notFound }
            return event
        }

        func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String) async throws -> GoogleCalendarEvent {
            insertCount += 1
            var saved = event; saved.etag = "inserted-\(insertCount)"
            remote[saved.id] = saved
            return saved
        }

        func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
            guard var event = remote[eventID] else { throw GmailError.notFound }
            guard event.etag == etag else { throw GmailError.http(status: 412, reason: nil) }
            patchETags.append(etag)
            for (key, value) in fields { event.rawValue[key] = value == .null ? nil : value }
            event.etag = "remote-\(patchETags.count)"
            remote[eventID] = event
            return event
        }
    }
}
