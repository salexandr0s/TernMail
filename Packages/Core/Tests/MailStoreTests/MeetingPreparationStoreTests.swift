import Foundation
import GmailAPI
import GRDB
import Testing
@testable import MailStore

private let preparationClock = Date(timeIntervalSince1970: 1_900_000_000)

@Suite struct MeetingPreparationStoreTests {
    @Test func recurringIdentityUsesOriginalStartAndCanonicalTimedInstant() throws {
        var event = preparationEvent()
        let original = try preparationOccurrence(event)
        event.id = "different-provider-instance-id"
        event.start = CalendarDateTime(dateTime: "2026-11-10T15:00:00Z")
        event.originalStartTime = CalendarDateTime(dateTime: "2026-11-03T11:00:00+01:00", timeZone: "Europe/Vienna")
        let moved = try preparationOccurrence(event)
        #expect(original == moved)
        #expect(original.id == moved.id)
        #expect(try JSONDecoder().decode(MeetingPreparationOccurrence.self, from: JSONEncoder().encode(original)) == original)

        event.originalStartTime = CalendarDateTime(dateTime: "2026-11-04T10:00:00Z")
        #expect(try preparationOccurrence(event) != original)
        event.originalStartTime = CalendarDateTime(date: "2026-11-03")
        #expect(try preparationOccurrence(event) != original)
        #expect(try MeetingPreparationOccurrence(eventAccountID: "mail", calendarID: "calendar", event: preparationEvent()) != original)
        #expect(try MeetingPreparationOccurrence(eventAccountID: "event", calendarID: "other", event: preparationEvent()) != original)
        var single = preparationEvent()
        single.recurringEventId = nil; single.originalStartTime = nil
        let singleIdentity = try preparationOccurrence(single)
        single.start = CalendarDateTime(dateTime: "2027-01-01T00:00:00Z")
        #expect(try preparationOccurrence(single) == singleIdentity)
        #expect(singleIdentity != original)
    }

    @Test func seriesMastersAndAmbiguousOrInvalidStartsCannotBecomeOccurrences() throws {
        var master = GoogleCalendarEvent(id: "series", start: CalendarDateTime(dateTime: "2026-11-03T10:00:00Z"))
        master.recurrence = ["RRULE:FREQ=WEEKLY"]
        #expect(throws: MeetingPreparationStoreError.requiresOccurrence) { try preparationOccurrence(master) }
        #expect(throws: MeetingPreparationStoreError.invalidOccurrence) { try preparationOccurrence(GoogleCalendarEvent()) }
        for start in [CalendarDateTime(), CalendarDateTime(date: "2026-02-30"),
                      CalendarDateTime(dateTime: "2026-11-03T10:00:00"),
                      CalendarDateTime(date: "2026-11-03", dateTime: "2026-11-03T10:00:00Z")] {
            var event = preparationEvent(); event.originalStartTime = start
            #expect(throws: MeetingPreparationStoreError.invalidOccurrence) { try preparationOccurrence(event) }
        }
        var missingOriginal = preparationEvent(); missingOriginal.originalStartTime = nil
        #expect(throws: MeetingPreparationStoreError.invalidOccurrence) { try preparationOccurrence(missingOriginal) }
        #expect(throws: MeetingPreparationStoreError.invalidOccurrence) {
            try MeetingPreparationOccurrence(eventAccountID: "", calendarID: "calendar", identity: .single(eventID: "id"))
        }
        #expect(throws: MeetingPreparationStoreError.invalidOccurrence) {
            try MeetingPreparationOccurrence(eventAccountID: "event", calendarID: "calendar",
                identity: .recurring(seriesID: "series", originalStart: .timed(instant: Date(timeIntervalSinceReferenceDate: .infinity))))
        }
    }

    @Test func includeExcludeRestoreRejectStaleEditsAndDeleteRecreateRaces() async throws {
        let store = try await preparationStore()
        let occurrence = try preparationOccurrence()
        let included = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail",
            threadID: "thread", choice: .include, now: preparationClock)
        let excluded = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail",
            threadID: "thread", choice: .exclude, expectedRevision: included.revision, now: preparationClock + 1)
        #expect(excluded.id == included.id)
        #expect(excluded.revision != included.revision)
        await #expect(throws: MeetingPreparationStoreError.conflict) {
            try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail",
                threadID: "thread", choice: .include, expectedRevision: included.revision)
        }
        await #expect(throws: MeetingPreparationStoreError.conflict) {
            try await store.restoreMeetingPreparationSource(occurrence: occurrence, mailAccountID: "mail",
                threadID: "thread", expectedRevision: included.revision)
        }
        #expect(try await store.meetingPreparationPreferences(for: occurrence) == [excluded])
        #expect(try await store.restoreMeetingPreparationSource(occurrence: occurrence, mailAccountID: "mail",
            threadID: "thread", expectedRevision: excluded.revision))
        #expect(try await store.meetingPreparationPreferences(for: occurrence).isEmpty)
        let recreated = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail",
            threadID: "thread", choice: .include, now: preparationClock + 2)
        #expect(recreated.revision != excluded.revision)
        await #expect(throws: MeetingPreparationStoreError.conflict) {
            try await store.restoreMeetingPreparationSource(occurrence: occurrence, mailAccountID: "mail",
                threadID: "thread", expectedRevision: excluded.revision)
        }
        #expect(try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail",
            threadID: "thread", choice: .include, expectedRevision: recreated.revision, now: preparationClock + 3) == recreated)
    }

    @Test func choicesSurviveReopenAndMirrorResetsWithoutChangingSourceLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.sqlite")
        let store = try AccountStore.open(at: url)
        try await seedPreparationAccounts(store)
        let occurrence = try preparationOccurrence()
        let excluded = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail",
            threadID: "thread", choice: .exclude, now: preparationClock)
        let calendar = try CalendarStore.inMemory()
        let link = CalendarSourceLink(accountID: "event", calendarID: "calendar", eventID: "instance", threadID: "thread", messageID: "message")
        try await calendar.saveSourceLink(link)
        try await calendar.cacheEvent(preparationEvent(), accountID: "event", calendarID: "calendar")
        try await calendar.resetRemoteCalendar(accountID: "event", calendarID: "calendar")
        let cache = try MailCache.inMemory()
        try await cache.resetDisposableCache()
        let reopened = try AccountStore.open(at: url)
        #expect(try await reopened.meetingPreparationPreferences(for: occurrence) == [excluded])
        #expect(try await calendar.sourceLinks(accountID: "event", calendarID: "calendar", eventID: "instance") == [link])
        var moved = preparationEvent(); moved.start = CalendarDateTime(dateTime: "2026-11-10T10:00:00Z")
        #expect(try await reopened.meetingPreparationPreferences(for: preparationOccurrence(moved)) == [excluded])
        var tomorrow = preparationEvent(); tomorrow.originalStartTime = CalendarDateTime(dateTime: "2026-11-04T10:00:00Z")
        #expect(try await reopened.meetingPreparationPreferences(for: preparationOccurrence(tomorrow)).isEmpty)
    }

    @Test func bothAccountSidesAreIsolatedObservedAndCascadeOnRemoval() async throws {
        let store = try await preparationStore()
        let occurrence = try preparationOccurrence()
        let first = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail",
            threadID: "same-thread", choice: .exclude, now: preparationClock)
        let second = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "other",
            threadID: "same-thread", choice: .include, now: preparationClock)
        #expect(first.id != second.id)
        var values = store.observeMeetingPreparationPreferences(for: occurrence).makeAsyncIterator()
        #expect(try await values.next() == [first, second])
        _ = try await store.beginAccountRemoval(accountID: "mail", draftIDs: [])
        #expect(try await values.next() == [second])
        await #expect(throws: MeetingPreparationStoreError.unavailableAccount) {
            try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail", threadID: "new", choice: .include)
        }
        try await store.deleteAccount(id: "mail")
        let retainedMailAccounts = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT mailAccountID FROM meetingPreparationPreference")
        }
        #expect(retainedMailAccounts == ["other"])
        let unrelatedOccurrence = try MeetingPreparationOccurrence(eventAccountID: "other", calendarID: "calendar", identity: .single(eventID: "event"))
        let unrelated = try await store.setMeetingPreparationPreference(occurrence: unrelatedOccurrence, mailAccountID: "other",
            threadID: "thread", choice: .include, now: preparationClock)
        _ = try await store.beginAccountRemoval(accountID: "event", draftIDs: [])
        #expect(try await values.next() == [])
        await #expect(throws: MeetingPreparationStoreError.unavailableAccount) { try await store.meetingPreparationPreferences(for: occurrence) }
        try await store.deleteAccount(id: "event")
        #expect(try await store.meetingPreparationPreferences(for: unrelatedOccurrence) == [unrelated])
        let count = try await store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetingPreparationPreference") }
        #expect(count == 1)
    }

    @Test func cancelledWritesAndInvalidStoredIdentityDoNotBecomeSuccessfulChoices() async throws {
        let store = try await preparationStore()
        let occurrence = try preparationOccurrence()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail", threadID: "thread", choice: .exclude)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.meetingPreparationPreferences(for: occurrence).isEmpty)
        await #expect(throws: MeetingPreparationStoreError.invalidPreference) {
            try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail", threadID: " ", choice: .exclude)
        }
        _ = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "mail", threadID: "thread", choice: .exclude)
        let wrong = try MeetingPreparationOccurrence(eventAccountID: "event", calendarID: "calendar", identity: .single(eventID: "unrelated"))
        let payload = String(decoding: try JSONEncoder().encode(wrong), as: UTF8.self)
        try await store.writer.write { db in try db.execute(sql: "UPDATE meetingPreparationPreference SET occurrence = ?", arguments: [payload]) }
        await #expect(throws: MeetingPreparationStoreError.invalidPreference) { try await store.meetingPreparationPreferences(for: occurrence) }
    }
}

private func preparationStore() async throws -> AccountStore {
    let store = try AccountStore.inMemory()
    try await seedPreparationAccounts(store)
    return store
}

private func seedPreparationAccounts(_ store: AccountStore) async throws {
    for id in ["event", "mail", "other"] {
        try await store.save(AccountRecord(id: id, email: "\(id)@example.com", displayName: nil, grantedScopes: [], addedAt: preparationClock))
    }
}

private func preparationEvent() -> GoogleCalendarEvent {
    var event = GoogleCalendarEvent(id: "instance", summary: "Project review", start: CalendarDateTime(dateTime: "2026-11-03T10:00:00Z"))
    event.recurringEventId = "series"
    event.originalStartTime = CalendarDateTime(dateTime: "2026-11-03T10:00:00Z")
    return event
}

private func preparationOccurrence(_ event: GoogleCalendarEvent = preparationEvent()) throws -> MeetingPreparationOccurrence {
    try MeetingPreparationOccurrence(eventAccountID: "event", calendarID: "calendar", event: event)
}
