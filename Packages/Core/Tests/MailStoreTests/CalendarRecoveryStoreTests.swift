import Foundation
import GmailAPI
import GRDB
import Testing
@testable import MailStore

@Suite struct CalendarRecoveryStoreTests {
    @Test func aFailedReconciliationTransactionKeepsThePendingReceiptAndSourceEvent() async throws {
        let store = try CalendarStore.inMemory()
        let event = GoogleCalendarEvent(id: "event", summary: "Meeting")
        try await store.cacheEvent(event, accountID: "a", calendarID: "c")
        var failed = CalendarOperation(accountID: "a", calendarID: "c",
            mutation: .move(eventID: event.id, destination: "other", etag: "v1"), status: .failed)
        failed.attempts = 1
        try await store.saveOperation(failed)
        var recovered = failed; recovered.status = .completed; recovered.resultEvent = event
        try await store.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_recovery_cache BEFORE INSERT ON calendarEvent
                WHEN NEW.calendarID = 'other' BEGIN SELECT RAISE(ABORT, 'injected cache failure'); END;
                """)
        }
        await #expect(throws: DatabaseError.self) { try await store.recoverOperation(expected: failed, with: recovered) }
        #expect(try await store.operation(id: failed.id) == failed)
        #expect(try await store.event(accountID: "a", calendarID: "c", eventID: event.id) == event)
        #expect(try await store.event(accountID: "a", calendarID: "other", eventID: event.id) == nil)
        try await store.writer.write { db in try db.execute(sql: "DROP TRIGGER fail_recovery_cache") }
        try await store.recoverOperation(expected: failed, with: recovered)
        #expect(try await store.operation(id: failed.id)?.status == .completed)
        #expect(try await store.event(accountID: "a", calendarID: "c", eventID: event.id) == nil)
        #expect(try await store.event(accountID: "a", calendarID: "other", eventID: event.id) == event)
    }

    @Test func aReviewCannotRequeueAReceiptChangedByAnotherRecovery() async throws {
        let store = try CalendarStore.inMemory()
        var failed = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(.init(summary: "Meeting")), status: .failed)
        failed.attempts = 1
        try await store.saveOperation(failed)
        var queued = failed; queued.status = .queued
        try await store.recoverOperation(expected: failed, with: queued)
        var cancelled = failed; cancelled.status = .cancelled
        await #expect(throws: CalendarStoreError.invalidRecord) { try await store.recoverOperation(expected: failed, with: cancelled) }
        #expect(try await store.operation(id: failed.id)?.status == .queued)
    }

    @Test func oldReceiptsDecodeWithoutAssumingAnAttemptWasRejected() throws {
        let operation = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(.init(summary: "Meeting")))
        let data = try JSONEncoder().encode(operation)
        var dictionary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dictionary["hasUncertainOutcome"] = nil
        let old = try JSONDecoder().decode(CalendarOperation.self, from: JSONSerialization.data(withJSONObject: dictionary))
        #expect(old.hasUncertainOutcome == nil)
    }
}
