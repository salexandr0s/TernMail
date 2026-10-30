import Foundation
import GmailAPI
import MailStore
import Testing
@testable import SyncEngine

@Suite struct CalendarSyncEngineTests {
    @Test func aFailedPageDoesNotAdvanceTheCursorOrPublishPartialEvents() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        let original = CalendarTestService.event(id: "old")
        try await store.applyEventSync([original], accountID: "a", calendarID: "c", token: "old-token",
                                      replacing: true, expected: .init())
        await api.configurePageFailure(true)
        await #expect(throws: GmailError.self) { try await engine.syncEvents(calendarID: "c") }
        #expect(try await store.syncState(accountID: "a", calendarID: "c").syncToken == "old-token")
        #expect(try await store.events(accountID: "a", calendarID: "c") == [original])
        await api.configurePageFailure(false)
        try await engine.syncEvents(calendarID: "c")
        #expect(try await store.syncState(accountID: "a", calendarID: "c").syncToken == "new-token")
    }

    @Test func aLostCreateResponseIsReconciledWithoutCreatingTwice() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        await api.configureInsertLoss()
        let op = try await engine.enqueue(.create(CalendarTestService.event(id: "")), calendarID: "c")
        try await engine.flush()
        #expect(try await store.operation(id: op.id)?.status == .queued)
        try await engine.flush()
        #expect(try await store.operation(id: op.id)?.status == .completed)
        #expect(await api.insertCount == 1)
    }

    @Test func expiredCursorRebuildKeepsPendingWork() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        try await store.applyEventSync([CalendarTestService.event(id: "old")], accountID: "a", calendarID: "c",
                                      token: "expired", replacing: true, expected: .init())
        let op = try await engine.enqueue(.create(CalendarTestService.event(id: "")), calendarID: "c")
        await api.put(CalendarTestService.event(id: "new"))
        try await engine.syncEvents(calendarID: "c")
        #expect(try await store.events(accountID: "a", calendarID: "c").map(\.id) == ["new"])
        #expect(try await store.operation(id: op.id)?.status == .queued)
        #expect(try await store.syncState(accountID: "a", calendarID: "c").syncToken == "sync-token")
    }

    @Test func importedExceptionsResumeUsingTheSavedInstanceIdentity() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        var master = CalendarTestService.event(id: "")
        master.iCalUID = "imported-series@example.invalid"; master.recurrence = ["RRULE:FREQ=WEEKLY"]
        var instance = CalendarTestService.event(id: "instance")
        instance.originalStartTime = instance.start; instance.recurringEventId = "imported"
        await api.put(instance)
        var exception = instance
        exception.start = CalendarDateTime(dateTime: "2027-01-02T10:00:00+01:00")
        exception.end = CalendarDateTime(dateTime: "2027-01-02T11:00:00+01:00")
        await api.configurePatchLoss()
        let op = try await engine.enqueue(.importSeries(master: master, exceptions: [exception]), calendarID: "c")
        try await engine.flush()
        #expect(try await store.operation(id: op.id)?.status == .queued)
        try await engine.flush()
        #expect(try await store.operation(id: op.id)?.status == .completed)
        #expect(await api.importCount == 1)
        #expect(await api.patchCount == 1)
        #expect(try await api.event(calendarID: "c", eventID: "instance").start == exception.start)
    }

    @Test func editsPreserveUnrelatedFieldsAndRejectChangedEtags() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        var event = CalendarTestService.event(id: "e")
        event.rawValue["providerField"] = .object(["keep": .bool(true)])
        await api.put(event)
        let edit = try await engine.enqueue(.update(eventID: "e", fields: ["summary": .string("Changed")], etag: "v1"),
                                            calendarID: "c", beforeEvent: event)
        #expect(try await store.operation(id: edit.id)?.beforeEvent == event)
        try await engine.flush()
        let saved = try await api.event(calendarID: "c", eventID: "e")
        #expect(saved.summary == "Changed")
        #expect(saved.rawValue["providerField"] == event.rawValue["providerField"])
        #expect(try await store.operation(id: edit.id)?.status == .completed)
        #expect(try await store.operation(id: edit.id)?.beforeEvent == event)
        let stale = try await engine.enqueue(.delete(eventID: "e", etag: "v1"), calendarID: "c")
        try await engine.flush()
        #expect(try await store.operation(id: stale.id)?.status == .conflicted)
        #expect(await api.deleteCount == 0)
    }

    @Test func incompleteAvailabilityNeverProducesSuggestedTimes() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        let start = try #require(CalendarDateCoding.date("2026-11-02T09:00:00+01:00"))
        let result = try await engine.availability(calendarIDs: ["c", "missing"], start: start,
            end: start.addingTimeInterval(3600), hours: .init(timeZoneIdentifier: "Europe/Vienna"))
        #expect(!result.isComplete)
        #expect(result.slots.isEmpty)
        #expect(result.failures["missing"] != nil)
    }

    @Test func recurringSplitResumesAfterAnUncertainTrim() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        var master = CalendarTestService.event(id: "series")
        master.start = CalendarDateTime(dateTime: "2026-10-26T10:00:00+01:00", timeZone: "Europe/Vienna")
        master.end = CalendarDateTime(dateTime: "2026-10-26T11:00:00+01:00", timeZone: "Europe/Vienna")
        master.recurrence = ["RRULE:FREQ=WEEKLY"]
        var exception = CalendarTestService.event(id: "exception")
        exception.recurringEventId = master.id
        exception.originalStartTime = CalendarDateTime(dateTime: "2026-11-09T10:00:00+01:00")
        await api.put(master); await api.put(exception); await api.configurePatchLoss()
        var following = master
        following.start = CalendarDateTime(dateTime: "2026-11-02T12:00:00+01:00", timeZone: "Europe/Vienna")
        following.end = CalendarDateTime(dateTime: "2026-11-02T13:00:00+01:00", timeZone: "Europe/Vienna")
        let op = try await engine.enqueue(.splitSeries(eventID: master.id, etag: master.etag,
            originalStart: CalendarDateTime(dateTime: "2026-11-02T10:00:00+01:00", timeZone: "Europe/Vienna"),
            followingEvent: following, resetExceptionsConfirmed: true), calendarID: "c")
        try await engine.flush()
        #expect(try await store.operation(id: op.id)?.status == .queued)
        try await engine.flush()
        #expect(try await store.operation(id: op.id)?.status == .completed)
        #expect(await api.patchCount == 1)
        #expect(await api.insertCount == 1)
        #expect(await api.deleteCount == 1)
        let trimmed = try await api.event(calendarID: "c", eventID: master.id)
        #expect(trimmed.recurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20261102T085959Z"])
    }

    @Test func compoundSeriesSplitPersistsThePartitionAcrossAnUncertainTrim() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        var master = CalendarTestService.event(id: "series")
        master.start = .init(dateTime: "2026-10-26T10:00:00+01:00", timeZone: "Europe/Vienna")
        master.end = .init(dateTime: "2026-10-26T11:00:00+01:00", timeZone: "Europe/Vienna")
        master.recurrence = ["RRULE:FREQ=WEEKLY;COUNT=5", "EXDATE;TZID=Europe/Vienna:20261102T100000,20261116T100000",
                             "RDATE:20261028T090000Z,20261111T090000Z"]
        await api.put(master); await api.configurePatchLoss()
        var following = master
        following.start = .init(dateTime: "2026-11-09T10:00:00+01:00", timeZone: "Europe/Vienna")
        following.end = .init(dateTime: "2026-11-09T11:00:00+01:00", timeZone: "Europe/Vienna")
        following.summary = "Changed series"
        let op = try await engine.enqueue(.splitSeries(eventID: master.id, etag: master.etag,
            originalStart: try #require(following.start), followingEvent: following, resetExceptionsConfirmed: true), calendarID: "c")
        try await engine.flush()
        let pending = try #require(try await store.operation(id: op.id))
        #expect(pending.status == .queued)
        #expect(pending.preparedRecurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20261109T085959Z",
            "EXDATE;TZID=Europe/Vienna:20261102T100000", "RDATE:20261028T090000Z"])
        try await engine.flush()
        let completed = try #require(try await store.operation(id: op.id))
        #expect(completed.status == .completed)
        #expect(completed.resultEvent?.recurrence == ["RRULE:FREQ=WEEKLY;COUNT=3",
            "EXDATE;TZID=Europe/Vienna:20261116T100000", "RDATE:20261111T090000Z"])
        #expect(await api.patchCount == 1)
        #expect(await api.insertCount == 1)
    }

    @Test func deletingAtTheFirstOccurrenceDoesNotNeedToInterpretComplexRecurrence() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        var master = CalendarTestService.event(id: "series")
        master.recurrence = ["RRULE:FREQ=WEEKLY", "EXRULE:FREQ=YEARLY", "RDATE;VALUE=PERIOD:20261103T100000Z/PT1H"]
        await api.put(master)
        let op = try await engine.enqueue(.deleteFollowing(eventID: master.id, etag: master.etag,
            originalStart: try #require(master.start)), calendarID: "c")
        try await engine.flush()
        #expect(try await store.operation(id: op.id)?.status == .completed)
        #expect(await api.deleteCount == 1)
        #expect(await api.patchCount == 0)
    }

    @Test func stopDrainsAnInflightReadBeforeAccountDeletion() async throws {
        let store = try CalendarStore.inMemory()
        let api = CalendarTestService()
        let engine = CalendarSyncEngine(accountID: "a", service: api, store: store)
        _ = try await engine.syncCalendars()
        await api.put(CalendarTestService.event(id: "e"))
        await api.holdNextRead()
        let read = Task { try await engine.readEvent(calendarID: "c", eventID: "e") }
        await api.waitForHeldRead()
        let stopped = Task { await engine.stop() }
        // Yield actor execution so stop invalidates the request before release.
        await Task.yield()
        await api.releaseRead()
        await stopped.value
        _ = try? await read.value
        try await store.deleteAccountData(accountID: "a")
        #expect(try await store.accountIDs().isEmpty)
        await #expect(throws: CalendarEngineError.self) { try await engine.syncCalendars() }
    }
}

private actor CalendarTestService: CalendarService {
    var remote: [String: GoogleCalendarEvent] = [:]
    var pageFailure: Bool?
    var loseInsert = false
    var losePatch = false
    var insertCount = 0
    var importCount = 0
    var patchCount = 0
    var deleteCount = 0
    var holdRead = false
    var heldRead: CheckedContinuation<Void, Never>?
    var readWaiters: [CheckedContinuation<Void, Never>] = []

    static func event(id: String) -> GoogleCalendarEvent {
        GoogleCalendarEvent(rawValue: ["id": .string(id), "etag": .string("v1"), "summary": .string("Meeting"),
            "iCalUID": .string(id + "@test"), "start": .object(["dateTime": .string("2026-11-02T10:00:00+01:00")]),
            "end": .object(["dateTime": .string("2026-11-02T11:00:00+01:00")])])
    }
    func put(_ event: GoogleCalendarEvent) { remote[event.id] = event }
    func configurePageFailure(_ value: Bool) { pageFailure = value }
    func configureInsertLoss() { loseInsert = true }
    func configurePatchLoss() { losePatch = true }
    func holdNextRead() { holdRead = true }
    func waitForHeldRead() async {
        if heldRead != nil { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage {
        CalendarListPage(items: [GoogleCalendarEntry(rawValue: ["id": .string("c"), "summary": .string("Calendar"), "accessRole": .string("owner")])])
    }
    func events(calendarID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
        if query.syncToken == "expired" { throw CalendarAPIError.syncTokenExpired }
        if let pageFailure {
            if query.pageToken == nil { return CalendarEventPage(items: [Self.event(id: "new")], nextPageToken: "second") }
            if pageFailure { throw GmailError.transport(.networkConnectionLost) }
            return CalendarEventPage(items: [], nextSyncToken: "new-token")
        }
        return CalendarEventPage(items: remote.values.filter { query.iCalUID == nil || $0.iCalUID == query.iCalUID }, nextSyncToken: "sync-token")
    }
    func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
        if holdRead {
            holdRead = false
            await withCheckedContinuation { continuation in
                heldRead = continuation
                let waiters = readWaiters; readWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        guard let event = remote[eventID] else { throw GmailError.notFound }
        return event
    }
    func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String) async throws -> GoogleCalendarEvent {
        insertCount += 1
        var saved = event; saved.etag = "v1"
        remote[saved.id] = saved
        if loseInsert { loseInsert = false; throw GmailError.transport(.networkConnectionLost) }
        return saved
    }
    func importEvent(calendarID: String, event: GoogleCalendarEvent) async throws -> GoogleCalendarEvent {
        importCount += 1
        var saved = event; saved.id = "imported"; saved.etag = "v1"; remote[saved.id] = saved
        return saved
    }
    func instances(calendarID: String, eventID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
        CalendarEventPage(items: remote.values.filter { $0.recurringEventId == eventID })
    }
    func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
        guard var event = remote[eventID] else { throw GmailError.notFound }
        guard etag == event.etag else { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        patchCount += 1
        for (key, value) in fields {
            if value == .null { event.rawValue.removeValue(forKey: key) } else { event.rawValue[key] = value }
        }
        event.etag = "v\(patchCount + 1)"; remote[eventID] = event
        if losePatch { losePatch = false; throw GmailError.transport(.networkConnectionLost) }
        return event
    }
    func deleteEvent(calendarID: String, eventID: String, etag: String?, sendUpdates: String) async throws {
        guard let event = remote[eventID] else { throw GmailError.notFound }
        guard etag == event.etag else { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        deleteCount += 1; remote.removeValue(forKey: eventID)
    }
    func freeBusy(calendarIDs: [String], start: Date, end: Date, timeZone: String) async throws -> CalendarFreeBusyResponse {
        CalendarFreeBusyResponse(calendars: ["c": CalendarFreeBusyCalendar()])
    }
}
