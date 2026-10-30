import Foundation
import GmailAPI
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct CalendarInteractionModelTests {
    @Test func selectedRangeReachesTheEditorWithoutCreatingAnEvent() async throws {
        try await withFixture { fixture in
            let start = try #require(CalendarDateCoding.date("2026-10-30T23:45:00+01:00"))
            let range = CalendarEventRange(start: start, end: start.addingTimeInterval(2700), isAllDay: false)
            fixture.model.beginNew(in: range)
            let draft = try #require(fixture.model.editor)
            #expect(draft.event.startDate == range.start)
            #expect(draft.event.endDate == range.end)
            #expect(draft.event.isAllDay == false)
            #expect(fixture.model.operations.isEmpty)
            fixture.model.editor = nil

            let first = fixture.model.calendar.startOfDay(for: start)
            let last = try #require(fixture.model.calendar.date(byAdding: .day, value: 3, to: first))
            fixture.model.beginNew(in: .init(start: first, end: last, isAllDay: true))
            #expect(fixture.model.editor?.event.start?.date == "2026-10-30")
            #expect(fixture.model.editor?.event.end?.date == "2026-11-02")
        }
    }

    @Test func gestureConversionSavesBothEndpointsAndCanBeUndone() async throws {
        try await withFixture { fixture in
            let source = try fixture.event("breakfast")
            let range = CalendarInteraction.moving(source, to: fixture.model.date, allDay: true, calendar: fixture.model.calendar)
            try await fixture.model.change(source, to: range)
            #expect(fixture.model.editor == nil)
            #expect(fixture.model.operations.count == 1)
            #expect(fixture.model.operations.first?.status == .completed)
            let saved = try fixture.event("breakfast")
            #expect(saved.isAllDay)
            #expect(saved.start == range.start)
            #expect(saved.end == range.end)
            #expect(saved.event.location == source.event.location)
            #expect(saved.event.iCalUID == source.event.iCalUID)
            await fixture.model.undo()
            let restored = try fixture.event("breakfast")
            #expect(restored.start == source.start)
            #expect(restored.end == source.end)
            #expect(!restored.isAllDay)
        }
    }

    @Test func guestAndRecurringGesturesRequireEditorReviewBeforeEnqueuing() async throws {
        try await withFixture { fixture in
            let guest = try fixture.event("review")
            let guestRange = CalendarInteraction.moving(guest, to: guest.start.addingTimeInterval(3600), calendar: fixture.model.calendar)
            try await fixture.model.change(guest, to: guestRange)
            #expect(fixture.model.editor?.source?.id == guest.id)
            #expect(fixture.model.editor?.event.startDate == guestRange.start)
            #expect(fixture.model.operations.isEmpty)
            fixture.model.editor = nil

            let recurring = try #require(fixture.model.events.first(where: { $0.event.recurringEventId == "planning" }))
            let range = CalendarInteraction.moving(recurring, to: recurring.start.addingTimeInterval(1800), calendar: fixture.model.calendar)
            try await fixture.model.change(recurring, to: range)
            for _ in 0..<100 where fixture.model.editor == nil { try await Task.sleep(for: .milliseconds(10)) }
            let draft = try #require(fixture.model.editor)
            #expect(draft.source?.id == recurring.id)
            #expect(draft.seriesMaster?.id == "planning")
            #expect(draft.event.startDate == range.start)
            #expect(draft.event.endDate == range.end)
            #expect(draft.editScope == .occurrence)
            #expect(fixture.model.operations.isEmpty)
        }
    }

    @Test func readOnlyLockedStaleAndNoOpGesturesDoNotWrite() async throws {
        try await withFixture { fixture in
            let readOnly = try fixture.event("focus")
            let readOnlyRange = CalendarInteraction.moving(readOnly, to: readOnly.start.addingTimeInterval(3600), calendar: fixture.model.calendar)
            await #expect(throws: CalendarModelError.self) { try await fixture.model.change(readOnly, to: readOnlyRange) }
            let source = try fixture.event("breakfast")
            try await fixture.model.change(source, to: CalendarEventRange(source))
            #expect(fixture.model.operations.isEmpty)

            let index = try #require(fixture.model.events.firstIndex(where: { $0.id == source.id }))
            fixture.model.events[index].event.rawValue["locked"] = .bool(true)
            let locked = fixture.model.events[index]
            let range = CalendarInteraction.moving(source, to: source.start.addingTimeInterval(900), calendar: fixture.model.calendar)
            await #expect(throws: CalendarModelError.self) { try await fixture.model.change(locked, to: range) }
            fixture.model.events[index] = source
            fixture.model.events[index].event.etag = "changed-elsewhere"
            await #expect(throws: CalendarModelError.self) { try await fixture.model.change(source, to: range) }
            #expect(fixture.model.operations.isEmpty)
        }
    }

    @Test func offlineMoveRemainsVisibleOutsideItsCachedWindowAndRejectsAnotherDrag() async throws {
        try await withFixture { fixture in
            let source = try fixture.event("breakfast")
            let start = try #require(fixture.model.calendar.date(byAdding: .day, value: 8, to: source.start))
            let range = CalendarInteraction.moving(source, to: start, calendar: fixture.model.calendar)
            await fixture.service.setOffline(true)
            try await fixture.model.change(source, to: range)
            let receipt = try #require(try await fixture.store.operations(accountID: fixture.accountID).first)
            #expect(receipt.status == .queued)
            #expect(receipt.beforeEvent == source.event)
            // A search result captured before the drag must not enqueue a second
            // mutation against the same server version.
            await #expect(throws: CalendarModelError.self) { try await fixture.model.delete(source) }
            var edited = source.event
            edited.summary = "Stale editor"
            await #expect(throws: CalendarModelError.self) {
                try await fixture.model.save(CalendarEditorDraft(event: edited, calendarKey: source.calendarKey, source: source))
            }

            fixture.model.date = start
            fixture.model.events = []
            await fixture.model.reloadOccurrences()
            let pending = try fixture.event("breakfast")
            #expect(pending.start == range.start)
            #expect(pending.end == range.end)
            #expect(pending.isPending)
            #expect(!pending.canEdit)
            await #expect(throws: CalendarModelError.self) {
                try await fixture.model.change(pending, to: .init(start: start.addingTimeInterval(900), end: range.end.addingTimeInterval(900), isAllDay: false))
            }
            #expect(try await fixture.store.operations(accountID: fixture.accountID).count == 1)

            await fixture.service.setOffline(false)
            try await fixture.engine.flush()
            await fixture.model.reloadOccurrences()
            let saved = try fixture.event("breakfast")
            #expect(saved.start == range.start)
            #expect(!saved.isPending)
            #expect(saved.canEdit)
        }
    }

    @Test func offlineCreationAndDeletionAreVisibleAndUndoCancelsTheirReceipts() async throws {
        try await withFixture { fixture in
            await fixture.service.setOffline(true)
            let start = CalendarLayout.date(at: 9 * 60, on: fixture.model.date, calendar: fixture.model.calendar)
            fixture.model.beginNew(in: .init(start: start, end: start.addingTimeInterval(3600), isAllDay: false))
            var draft = try #require(fixture.model.editor)
            draft.event.summary = "Offline event"
            try await fixture.model.save(draft)
            let pending = try #require(fixture.model.events.first(where: { $0.title == "Offline event" }))
            #expect(pending.isPending)
            #expect(!pending.canEdit)
            await fixture.model.undo()
            #expect(!fixture.model.events.contains(where: { $0.title == "Offline event" }))

            let source = try fixture.event("breakfast")
            try await fixture.model.delete(source)
            #expect(!fixture.model.events.contains(where: { $0.id == source.id }))
            await fixture.model.undo()
            #expect(try fixture.event("breakfast").start == source.start)
            #expect(fixture.model.operations.allSatisfy { $0.status == .cancelled })
        }
    }

    @Test func failedProjectionKeepsTheServerPositionAndRequiresReview() async throws {
        try await withFixture { fixture in
            let source = try fixture.event("breakfast")
            let range = CalendarInteraction.moving(source, to: source.start.addingTimeInterval(3600), calendar: fixture.model.calendar)
            var operation = CalendarOperation(accountID: fixture.accountID, calendarID: source.calendarID,
                mutation: .update(eventID: source.event.id,
                    fields: range.applying(to: source.event, calendar: fixture.model.calendar).changedFields(from: source.event), etag: source.event.etag),
                status: .conflicted)
            operation.beforeEvent = source.event
            let projected = CalendarPendingEvents.project([source], operations: [operation], calendars: fixture.model.calendars,
                                                          interval: fixture.model.displayInterval, calendar: fixture.model.calendar)
            let restored = try #require(projected.first)
            #expect(restored.start == source.start)
            #expect(!restored.isPending)
            #expect(!restored.canEdit)
        }
    }

    @Test func duplicateFromReadOnlyRecurringCalendarIsAnIndependentWritableEvent() async throws {
        try await withFixture { fixture in
            var source = try fixture.event("focus")
            source.event.recurrence = ["RRULE:FREQ=WEEKLY"]
            source.event.recurringEventId = "source-series"
            source.event.attendees = [CalendarAttendee(email: "guest@example.invalid")]
            source.event.eventType = "focusTime"
            source.event.rawValue["focusTimeProperties"] = .object(["autoDeclineMode": .string("declineAllConflictingInvitations")])
            fixture.model.duplicate(source)
            let draft = try #require(fixture.model.editor)
            #expect(draft.isNew)
            #expect(fixture.model.calendars.contains(where: { $0.id == draft.calendarKey && $0.canWrite }))
            #expect(draft.event.recurrence == nil)
            #expect(draft.event.recurringEventId == nil)
            #expect(draft.event.attendees == nil)
            #expect(draft.event.iCalUID == nil)
            #expect(draft.event.eventType == nil)
            #expect(draft.event.rawValue["focusTimeProperties"] == nil)
        }
    }

    @Test func searchDoesNotAllowLockedOrPendingResultsToBeChanged() async throws {
        try await withFixture { fixture in
            let source = try fixture.event("breakfast")
            _ = try await fixture.service.patchEvent(calendarID: source.calendarID, eventID: source.event.id,
                fields: ["locked": .bool(true)], etag: source.event.etag, sendUpdates: "none")
            fixture.model.searchText = "Coffee"
            await fixture.model.searchEvents()
            let locked = try #require(fixture.model.searchResults.first(where: { $0.id == source.id }))
            #expect(!locked.canEdit)
            await #expect(throws: CalendarModelError.self) { try await fixture.model.delete(locked) }

            let other = try fixture.event("design")
            let range = CalendarInteraction.moving(other, to: other.start.addingTimeInterval(900), calendar: fixture.model.calendar)
            await fixture.service.setOffline(true)
            try await fixture.model.change(other, to: range)
            await fixture.service.setOffline(false)
            fixture.model.searchText = "Design"
            await fixture.model.searchEvents()
            let pending = try #require(fixture.model.searchResults.first(where: { $0.id == other.id }))
            #expect(!pending.canEdit)
            #expect(fixture.model.operations.first?.status == .queued)
        }
    }

    @Test func queuedSeriesUpdateDoesNotPaintItsMasterAnchorOverExpandedOccurrences() async throws {
        try await withFixture { fixture in
            let occurrence = try #require(fixture.model.events.first(where: { $0.event.recurringEventId == "planning" }))
            let master = try await fixture.service.event(calendarID: occurrence.calendarID, eventID: "planning")
            var operation = CalendarOperation(accountID: fixture.accountID, calendarID: occurrence.calendarID,
                mutation: .update(eventID: master.id, fields: ["recurrence": .null], etag: master.etag), status: .queued)
            operation.beforeEvent = master
            let result = CalendarPendingEvents.project([occurrence], operations: [operation], calendars: fixture.model.calendars,
                                                      interval: fixture.model.displayInterval, calendar: fixture.model.calendar)
            #expect(result.count == 1)
            #expect(result.first?.id == occurrence.id)
            #expect(result.first?.start == occurrence.start)
            #expect(result.first?.isPending == true)
            #expect(result.first?.canEdit == false)
        }
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @MainActor private final class Fixture {
        let accountID = "interaction-test"
        let defaultsName = "CalendarInteractionModelTests." + UUID().uuidString
        let defaults: UserDefaults
        let model: CalendarModel
        let service: OfflineCalendarService
        let store: CalendarStore
        let engine: CalendarSyncEngine

        init() async throws {
            let date = try #require(CalendarDateCoding.date("2026-10-30T12:00:00+01:00"))
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            store = try CalendarStore.inMemory()
            service = OfflineCalendarService(now: date)
            engine = CalendarSyncEngine(accountID: accountID, service: service, store: store)
            model = CalendarModel(app: nil, defaults: defaults)
            model.date = date
            model.workingHours = CalendarWorkingHours(timeZoneIdentifier: "Europe/Vienna")
            model.firstWeekday = 2
            model.store = store
            model.engines = [accountID: engine]
            let entries = try await engine.syncCalendars()
            model.calendars = entries.map { CalendarDisplayCalendar(entry: $0, accountID: accountID, accountName: "Synthetic calendar") }
            await model.reloadOccurrences()
        }

        func event(_ id: String) throws -> CalendarDisplayEvent {
            try #require(model.events.first(where: { $0.event.id == id }))
        }

        func close() async {
            await model.stop()
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private actor OfflineCalendarService: CalendarService {
        let underlying: CalendarAuditService
        private var offline = false
        init(now: Date) { underlying = CalendarAuditService(now: now) }
        func setOffline(_ value: Bool) { offline = value }
        private func checkConnection() throws { if offline { throw GmailError.transport(.notConnectedToInternet) } }
        func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage {
            try checkConnection()
            return try await underlying.calendarList(pageToken: pageToken, syncToken: syncToken)
        }
        func events(calendarID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
            try checkConnection()
            return try await underlying.events(calendarID: calendarID, query: query)
        }
        func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
            try checkConnection()
            return try await underlying.event(calendarID: calendarID, eventID: eventID)
        }
        func instances(calendarID: String, eventID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
            try checkConnection()
            return try await underlying.instances(calendarID: calendarID, eventID: eventID, query: query)
        }
        func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String) async throws -> GoogleCalendarEvent {
            try checkConnection()
            return try await underlying.insertEvent(calendarID: calendarID, event: event, sendUpdates: sendUpdates)
        }
        func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
            try checkConnection()
            return try await underlying.patchEvent(calendarID: calendarID, eventID: eventID, fields: fields, etag: etag, sendUpdates: sendUpdates)
        }
        func deleteEvent(calendarID: String, eventID: String, etag: String?, sendUpdates: String) async throws {
            try checkConnection()
            try await underlying.deleteEvent(calendarID: calendarID, eventID: eventID, etag: etag, sendUpdates: sendUpdates)
        }
    }
}
