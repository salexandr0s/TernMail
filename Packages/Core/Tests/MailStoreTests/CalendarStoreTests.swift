import Foundation
import GmailAPI
import Testing
@testable import MailStore

@Suite struct CalendarStoreTests {
    @Test func remoteResetKeepsLocalWorkAndRejectsOldWindows() async throws {
        let store = try CalendarStore.inMemory()
        let event = Self.event()
        let operation = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(event))
        let preference = CalendarPreferences(accountID: "a", calendarID: "c", assistantAccess: .details)
        try await store.saveOperation(operation)
        try await store.savePreferences(preference)
        let source = CalendarSourceLink(accountID: "a", calendarID: "c", eventID: event.id, threadID: "t", messageID: "m")
        try await store.saveSourceLink(source)
        let old = try await store.syncState(accountID: "a", calendarID: "c")
        try await store.applyEventSync([event], accountID: "a", calendarID: "c", token: "one", replacing: true, expected: old)
        let beforeReset = try await store.syncState(accountID: "a", calendarID: "c")
        try await store.resetRemoteCalendar(accountID: "a", calendarID: "c")
        #expect(try await store.events(accountID: "a", calendarID: "c").isEmpty)
        #expect(try await store.operation(id: operation.id) == operation)
        #expect(try await store.preferences(accountID: "a") == [preference])
        #expect(try await store.sourceLinks(accountID: "a") == [source])
        await #expect(throws: CalendarStoreError.self) {
            try await store.saveOccurrences([event], accountID: "a", calendarID: "c", start: .distantPast,
                                             end: .distantFuture, expected: beforeReset)
        }
        await #expect(throws: CalendarStoreError.self) {
            try await store.cacheEvent(event, accountID: "a", calendarID: "c", expected: beforeReset)
        }
        #expect(try await store.syncState(accountID: "a", calendarID: "c").syncToken == nil)
    }

    @Test func identityIncludesAccountAndCalendarAndDeletionIsScoped() async throws {
        let store = try CalendarStore.inMemory()
        let event = Self.event()
        for account in ["a", "b"] {
            for calendar in ["c", "d"] { try await store.cacheEvent(event, accountID: account, calendarID: calendar) }
        }
        let op = CalendarOperation(accountID: "b", calendarID: "c", mutation: .create(event))
        try await store.saveOperation(op)
        #expect(try await store.operation(accountID: "a", id: op.id) == nil)
        try await store.deleteAccountData(accountID: "a")
        #expect(try await store.events(accountID: "a", calendarID: "c").isEmpty)
        #expect(try await store.events(accountID: "b", calendarID: "c") == [event])
        #expect(try await store.events(accountID: "b", calendarID: "d") == [event])
    }

    @Test func refreshingSuggestionsPreservesCorrectionsAndDismissals() async throws {
        let store = try CalendarStore.inMemory()
        var suggestion = CalendarSuggestionRecord(id: "suggestion", accountID: "a", threadID: "t", messageID: "m",
            sourceRevision: "one", event: Self.event(), sourceText: "Friday at noon", isUserEdited: true)
        try await store.saveSuggestion(suggestion)
        var replacement = suggestion
        replacement.sourceRevision = "two"; replacement.event.summary = "Generated replacement"; replacement.isUserEdited = false
        try await store.saveSuggestion(replacement)
        #expect(try await store.suggestions(accountID: "a", threadID: "t") == [suggestion])
        suggestion.isDismissed = true
        try await store.saveSuggestion(suggestion, preservingCorrections: false)
        #expect(try await store.suggestions(accountID: "a", threadID: "t").first?.isDismissed == true)
    }

    @Test func cancelledOperationsCannotBeClaimedAndAttemptedOperationsCannotBeReplaced() async throws {
        let store = try CalendarStore.inMemory()
        let first = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(Self.event()), status: .queued)
        try await store.saveOperation(first)
        #expect(try await store.cancelOperation(accountID: "a", id: first.id))
        #expect(try await store.claimOperation(accountID: "a", id: first.id) == nil)
        let second = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(Self.event()), status: .queued)
        try await store.saveOperation(second)
        #expect(try await store.claimOperation(accountID: "a", id: second.id)?.status == .running)
        #expect(try await store.cancelOperation(accountID: "a", id: second.id) == false)
        let replacement = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(Self.event()), status: .queued)
        await #expect(throws: CalendarStoreError.self) {
            try await store.replaceOperation(accountID: "a", id: second.id, with: replacement)
        }
        #expect(try await store.operation(id: replacement.id) == nil)
    }

    @Test func losingDetailAccessPurgesTitlesAndLosingWriteAccessStopsTheQueue() async throws {
        let store = try CalendarStore.inMemory()
        let entry = GoogleCalendarEntry(rawValue: ["id": .string("c"), "accessRole": .string("writer")])
        try await store.replaceCalendars([entry], accountID: "a")
        let event = Self.event()
        try await store.cacheEvent(event, accountID: "a", calendarID: "c")
        try await store.saveOccurrences([event], accountID: "a", calendarID: "c", start: .distantPast,
                                       end: .distantFuture, expected: .init())
        let queued = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(event), status: .queued)
        try await store.saveOperation(queued)
        var limited = entry; limited.accessRole = "freeBusyReader"
        try await store.replaceCalendars([limited], accountID: "a")
        #expect(try await store.events(accountID: "a", calendarID: "c").isEmpty)
        #expect(try await store.cachedOccurrences(accountID: "a", calendarID: "c", start: .distantPast, end: .distantFuture).isComplete == false)
        #expect(try await store.operation(id: queued.id)?.status == .failed)
        #expect(try await store.claimOperation(accountID: "a", id: queued.id) == nil)
    }

    @Test func pendingInvitationRepliesAreDeduplicatedInTheQueueTransaction() async throws {
        let store = try CalendarStore.inMemory()
        let first = CalendarOperation(accountID: "a", calendarID: "c", mutation: .respond(eventID: "e", status: "accepted", etag: "v1"), status: .queued)
        let duplicate = CalendarOperation(accountID: "a", calendarID: "c", mutation: first.mutation, status: .queued)
        #expect(try await store.enqueueOperation(first).id == first.id)
        #expect(try await store.enqueueOperation(duplicate).id == first.id)
        let different = CalendarOperation(accountID: "a", calendarID: "c", mutation: .respond(eventID: "e", status: "declined", etag: "v1"), status: .queued)
        await #expect(throws: CalendarStoreError.self) { try await store.enqueueOperation(different) }
        #expect(try await store.operations(accountID: "a").count == 1)
    }

    @Test func allDayOfflineRangesUseTheCalendarTimeZoneAndExclusiveEnd() async throws {
        let store = try CalendarStore.inMemory()
        let entry = GoogleCalendarEntry(rawValue: ["id": .string("c"), "timeZone": .string("Pacific/Honolulu"), "accessRole": .string("reader")])
        try await store.replaceCalendars([entry], accountID: "a")
        let event = GoogleCalendarEvent(rawValue: ["id": .string("day"), "start": .object(["date": .string("2026-11-02")]),
                                                   "end": .object(["date": .string("2026-11-03")])])
        let start = try #require(CalendarDateCoding.date("2026-11-02T10:00:00Z"))
        let end = try #require(CalendarDateCoding.date("2026-11-03T10:00:00Z"))
        try await store.saveOccurrences([event], accountID: "a", calendarID: "c", start: start.addingTimeInterval(-86400),
                                       end: end.addingTimeInterval(86400), expected: .init())
        #expect(try await store.cachedOccurrences(accountID: "a", calendarID: "c", start: end.addingTimeInterval(-60), end: end).events == [event])
        #expect(try await store.cachedOccurrences(accountID: "a", calendarID: "c", start: end, end: end.addingTimeInterval(60)).events.isEmpty)
    }

    static func event() -> GoogleCalendarEvent {
        GoogleCalendarEvent(rawValue: ["id": .string("same"), "summary": .string("Meeting"),
            "start": .object(["dateTime": .string("2026-11-02T10:00:00+01:00")]),
            "end": .object(["dateTime": .string("2026-11-02T11:00:00+01:00")])])
    }
}
