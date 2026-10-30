import Foundation
import GmailAPI
import Testing
@testable import MailStore

@Suite struct CalendarEmailCacheTests {
    @Test func emptyInterpretationIsCachedByAccountThreadAndRevisionAndRemovedWithAccount() async throws {
        let store = try CalendarStore.inMemory()
        let empty = Data("[]".utf8)
        try await store.saveEmailInterpretation(empty, accountID: "first", threadID: "same-thread", revision: "v1")
        #expect(try await store.emailInterpretation(accountID: "first", threadID: "same-thread", revision: "v1") == empty)
        #expect(try await store.emailInterpretation(accountID: "other", threadID: "same-thread", revision: "v1") == nil)
        #expect(try await store.emailInterpretation(accountID: "first", threadID: "same-thread", revision: "v2") == nil)
        try await store.saveEmailInterpretation(Data("[1]".utf8), accountID: "first", threadID: "same-thread", revision: "v2")
        #expect(try await store.emailInterpretation(accountID: "first", threadID: "same-thread", revision: "v1") == nil)
        try await store.deleteAccountData(accountID: "first")
        #expect(try await store.emailInterpretation(accountID: "first", threadID: "same-thread", revision: "v2") == nil)
    }

    @Test func concurrentDetectedEventSavesRetainOneReceiptBeforeAnyFollowUpCallback() async throws {
        let store = try CalendarStore.inMemory()
        let candidate = CalendarSuggestionRecord(id: "source", accountID: "account", threadID: "thread", messageID: "message",
            sourceRevision: "v1", event: GoogleCalendarEvent(summary: "Detected meeting"), sourceText: "Friday at noon")
        try await store.saveSuggestion(candidate)
        let first = CalendarOperation(id: "first", accountID: "account", calendarID: "calendar",
            mutation: .create(GoogleCalendarEvent(id: "remote-first", summary: "Reviewed title")), status: .queued, sourceSuggestionID: "source")
        let second = CalendarOperation(id: "second", accountID: "account", calendarID: "calendar",
            mutation: .create(GoogleCalendarEvent(id: "remote-second", summary: "Other title")), status: .queued, sourceSuggestionID: "source")
        async let one = store.enqueueOperation(first)
        async let two = store.enqueueOperation(second)
        let receipts = try await [one, two]
        #expect(receipts[0].id == receipts[1].id)
        #expect(try await store.operations(accountID: "account").count == 1)
        let persisted = try #require(try await store.suggestion(id: "source"))
        #expect(persisted.operationID == receipts[0].id)
        #expect(persisted.isUserEdited)
        #expect(persisted.event.id == receipts[0].mutation.eventID)
        // Reopening after the process died before the app's source-link callback still reuses it.
        #expect(try await store.enqueueOperation(second).id == receipts[0].id)
    }

    @Test func revisedCandidateReceiptMovesAtomicallyAndForeignAccountRollsBack() async throws {
        let store = try CalendarStore.inMemory()
        try await store.saveSuggestion(CalendarSuggestionRecord(id: "source", accountID: "account", threadID: "thread", messageID: "message",
            sourceRevision: "v1", event: GoogleCalendarEvent(summary: "Detected meeting"), sourceText: "Friday at noon"))
        let first = CalendarOperation(id: "first", accountID: "account", calendarID: "calendar",
            mutation: .create(GoogleCalendarEvent(id: "remote-first", summary: "Meeting")), status: .queued, sourceSuggestionID: "source")
        _ = try await store.enqueueOperation(first)
        let replacement = CalendarOperation(id: "replacement", accountID: "account", calendarID: "calendar",
            mutation: .create(GoogleCalendarEvent(id: "remote-replacement", summary: "Corrected")), status: .queued)
        try await store.replaceOperation(accountID: "account", id: first.id, with: replacement)
        #expect(try await store.operation(id: first.id)?.status == .cancelled)
        #expect(try await store.operation(id: replacement.id)?.sourceSuggestionID == "source")
        #expect(try await store.suggestion(id: "source")?.operationID == replacement.id)
        let foreign = CalendarOperation(id: "foreign", accountID: "other", calendarID: "calendar",
            mutation: .create(GoogleCalendarEvent(id: "remote-foreign", summary: "Wrong account")), status: .queued, sourceSuggestionID: "source")
        await #expect(throws: CalendarStoreError.self) { try await store.enqueueOperation(foreign) }
        #expect(try await store.operation(id: "foreign") == nil)
        #expect(try await store.suggestion(id: "source")?.operationID == replacement.id)
    }
}
