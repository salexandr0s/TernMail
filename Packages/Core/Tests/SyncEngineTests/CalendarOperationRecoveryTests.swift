import Foundation
import GmailAPI
import MailStore
import Testing
@testable import SyncEngine

@Suite struct CalendarOperationRecoveryTests {
    @Test func responseConflictUsesTheReviewedVersionAndRejectsANewerChange() async throws {
        let (store, service, engine) = try await setup()
        var event = RecoveryCalendarService.event("invite")
        event.attendees = [.init(rawValue: ["email": .string("me@example.invalid"), "self": .bool(true), "responseStatus": .string("needsAction")])]
        await service.put(event)
        let operation = try await engine.enqueue(.respond(eventID: event.id, status: "accepted", etag: "old"), calendarID: "c")
        try await engine.flush()
        let first = try await engine.reviewRecovery(operationID: operation.id)
        #expect(first.currentEvents == [event])
        #expect(await service.patchCount == 0)
        event.summary = "Changed remotely"; event.etag = "v2"
        await service.put(event)
        await #expect(throws: CalendarEngineError.conflict) { try await engine.resumeRecovery(first) }
        #expect(await service.patchCount == 0)
        let fresh = try await engine.reviewRecovery(operationID: operation.id)
        try await engine.resumeRecovery(fresh)
        try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .completed)
        #expect(await service.patchCount == 1)
        #expect(try await service.event(calendarID: "c", eventID: event.id).summary == event.summary)
    }

    @Test func anUncertainMoveIsReconciledWithoutMovingAgain() async throws {
        let (store, service, engine) = try await setup()
        let event = RecoveryCalendarService.event("move")
        await service.put(event)
        await service.failAfterMove()
        let operation = try await engine.enqueue(.move(eventID: event.id, destination: "other", etag: event.etag), calendarID: "c")
        try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .failed)
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(review.isAlreadyApplied)
        try await engine.resumeRecovery(review)
        try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .completed)
        #expect(await service.moveCount == 1)
        #expect(try await store.event(accountID: "a", calendarID: "other", eventID: event.id) != nil)
    }

    @Test func partialSplitKeepsItsPartitionAndReviewsOnlyRemainingExceptions() async throws {
        let (store, service, engine) = try await setup()
        let master = RecoveryCalendarService.series()
        var exception = RecoveryCalendarService.event("exception")
        exception.recurringEventId = master.id
        exception.originalStartTime = .init(dateTime: "2026-11-09T10:00:00+01:00")
        await service.put(master); await service.put(exception)
        await service.changeExceptionBeforeDelete()
        let operation = try await engine.enqueue(split(master), calendarID: "c")
        try await engine.flush()
        let failed = try #require(try await store.operation(id: operation.id))
        #expect(failed.status == .conflicted)
        #expect(failed.completedStep == 1)
        let partition = failed.preparedRecurrence
        let following = failed.preparedMutation
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(!review.canEdit)
        #expect(!review.canDiscard)
        #expect(review.currentEvents.contains { $0.id == "exception" && $0.etag == "changed" })
        try await engine.resumeRecovery(review)
        let queued = try #require(try await store.operation(id: operation.id))
        #expect(queued.id == failed.id)
        #expect(queued.completedStep == 1)
        #expect(queued.preparedRecurrence == partition)
        #expect(queued.preparedMutation == following)
        try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .completed)
        #expect(await service.patchCount == 1)
        #expect(await service.deleteCount == 1)
        #expect(await service.insertCount == 1)
    }

    @Test func anUncertainTrimAndAnUncertainCreateAreEachReconciledOnce() async throws {
        let (store, service, engine) = try await setup()
        let master = RecoveryCalendarService.series()
        await service.put(master); await service.failAfterPatch()
        let operation = try await engine.enqueue(split(master), calendarID: "c")
        try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.completedStep == 0)
        let trimmed = try await engine.reviewRecovery(operationID: operation.id)
        #expect(trimmed.completedStep == 1)
        #expect(!trimmed.canDiscard)
        await service.failAfterInsert()
        try await engine.resumeRecovery(trimmed); try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .failed)
        let created = try await engine.reviewRecovery(operationID: operation.id)
        #expect(created.isAlreadyApplied)
        try await engine.resumeRecovery(created); try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .completed)
        #expect(await service.patchCount == 1)
        #expect(await service.insertCount == 1)
    }

    @Test func deleteFollowingResumesWithoutRepeatingItsSavedTrim() async throws {
        let (store, service, engine) = try await setup()
        let master = RecoveryCalendarService.series()
        var exception = RecoveryCalendarService.event("exception")
        exception.recurringEventId = master.id
        exception.originalStartTime = .init(dateTime: "2026-11-09T10:00:00+01:00")
        await service.put(master); await service.put(exception); await service.changeExceptionBeforeDelete()
        let operation = try await engine.enqueue(.deleteFollowing(eventID: master.id, etag: master.etag,
            originalStart: .init(dateTime: "2026-11-02T10:00:00+01:00")), calendarID: "c")
        try await engine.flush()
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(review.completedStep == 1)
        try await engine.resumeRecovery(review); try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .completed)
        #expect(await service.patchCount == 1)
        #expect(await service.deleteCount == 1)
    }

    @Test func aRejectedCreateCanBeEditedWithoutChangingItsIdentity() async throws {
        let (store, service, engine) = try await setup()
        await service.rejectNextInsert()
        let operation = try await engine.enqueue(.create(RecoveryCalendarService.event("")), calendarID: "c")
        try await engine.flush()
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(review.canEdit)
        #expect(review.canDiscard)
        var edited = RecoveryCalendarService.event("")
        edited.summary = "Corrected event"
        let revised = try await engine.reviseRecovery(review, mutation: .create(edited))
        #expect(revised.id == operation.id)
        #expect(revised.attempts == 1)
        try await engine.flush()
        let receipt = try #require(try await store.operation(id: operation.id))
        #expect(receipt.status == .completed)
        #expect(receipt.resultEvent?.summary == "Corrected event")
        #expect(try await store.operations(accountID: "a").count == 1)
    }

    @Test func aCreateThatArrivesDuringReviewCannotBeRevisedIntoASecondEvent() async throws {
        let (store, service, engine) = try await setup()
        await service.rejectNextInsert()
        let operation = try await engine.enqueue(.create(RecoveryCalendarService.event("")), calendarID: "c")
        try await engine.flush()
        let review = try await engine.reviewRecovery(operationID: operation.id)
        var arrived = RecoveryCalendarService.event(operation.id.replacingOccurrences(of: "-", with: ""))
        CalendarSyncEngine.mark(&arrived, marker: operation.id)
        await service.put(arrived)
        await #expect(throws: CalendarEngineError.conflict) {
            try await engine.reviseRecovery(review, mutation: .create(RecoveryCalendarService.event("")))
        }
        #expect(try await store.operations(accountID: "a").count == 1)
        let fresh = try await engine.reviewRecovery(operationID: operation.id)
        #expect(fresh.isAlreadyApplied)
        try await engine.resumeRecovery(fresh)
        #expect(try await store.operation(id: operation.id)?.status == .completed)
    }

    @Test func aDestinationCopyDoesNotProveThatAFailedMoveSucceeded() async throws {
        let (store, service, engine) = try await setup()
        let source = RecoveryCalendarService.event("source")
        var copy = source; copy.id = "independent-copy"
        await service.put(source); await service.put(copy, calendarID: "other")
        await service.rejectNextMove()
        let operation = try await engine.enqueue(.move(eventID: source.id, destination: "other", etag: source.etag), calendarID: "c")
        try await engine.flush()
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(!review.isAlreadyApplied)
        #expect(review.currentEvents.first?.id == source.id)
        #expect(try await service.event(calendarID: "c", eventID: source.id) == source)
        try await engine.resumeRecovery(review); try await engine.flush()
        #expect(await service.moveCount == 1)
        #expect(try await store.operation(id: operation.id)?.status == .completed)
    }

    @Test(arguments: [false, true])
    func importedExceptionRecoveryKeepsTheImportedMasterAndReviewedInstance(cancelled: Bool) async throws {
        let (store, service, engine) = try await setup()
        var master = RecoveryCalendarService.series(); master.id = ""
        var instance = RecoveryCalendarService.event("instance")
        instance.originalStartTime = instance.start; instance.recurringEventId = "imported"
        await service.put(instance)
        var exception = instance
        if cancelled { exception.status = "cancelled" }
        else { exception.summary = "Imported exception title" }
        await service.changeInstanceBeforePatch(cancelled: cancelled)
        let operation = try await engine.enqueue(.importSeries(master: master, exceptions: [exception]), calendarID: "c", sendUpdates: "none")
        try await engine.flush()
        let failed = try #require(try await store.operation(id: operation.id))
        #expect(failed.status == .conflicted)
        #expect(failed.completedStep == 1)
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(!review.canEdit)
        #expect(!review.canDiscard)
        #expect(review.isAlreadyApplied == cancelled)
        try await engine.resumeRecovery(review); try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .completed)
        #expect(await service.importCount == 1)
        #expect(await service.patchCount == (cancelled ? 0 : 1))
        let saved = try await service.event(calendarID: "c", eventID: instance.id)
        #expect(cancelled ? saved.isCancelled : saved.summary == exception.summary)
    }

    @Test func anUncertainCreateKeepsItsPayloadUntilItCanBeReconciled() async throws {
        let (store, service, engine) = try await setup()
        var operation = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(RecoveryCalendarService.event("")), status: .failed)
        operation.attempts = 1; operation.hasUncertainOutcome = true
        try await store.saveOperation(operation)
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(!review.canEdit)
        #expect(!review.canDiscard)
        await #expect(throws: CalendarEngineError.invalidOperation) {
            try await engine.reviseRecovery(review, mutation: .create(RecoveryCalendarService.event("")))
        }
        try await engine.resumeRecovery(review); try await engine.flush()
        #expect(try await store.operation(id: operation.id)?.status == .completed)
        #expect(await service.insertCount == 1)
    }

    @Test func reclaimingARunningReceiptKeepsCrashUncertaintyAfterARejectedRetry() async throws {
        let (store, service, engine) = try await setup()
        var operation = CalendarOperation(accountID: "a", calendarID: "c", mutation: .create(RecoveryCalendarService.event("")), status: .running)
        operation.attempts = 1
        #expect(operation.hasUncertainOutcome == false)
        try await store.saveOperation(operation)
        await service.rejectNextInsert()
        try await engine.flush()
        let recovered = try #require(try await store.operation(id: operation.id))
        #expect(recovered.status == .failed)
        #expect(recovered.hasUncertainOutcome == true)
        let review = try await engine.reviewRecovery(operationID: operation.id)
        #expect(!review.canEdit)
        #expect(!review.canDiscard)
    }

    private func setup() async throws -> (CalendarStore, RecoveryCalendarService, CalendarSyncEngine) {
        let store = try CalendarStore.inMemory()
        let service = RecoveryCalendarService()
        let engine = CalendarSyncEngine(accountID: "a", service: service, store: store)
        _ = try await engine.syncCalendars()
        return (store, service, engine)
    }

    private func split(_ master: GoogleCalendarEvent) -> CalendarMutation {
        var following = master
        following.start = .init(dateTime: "2026-11-02T10:00:00+01:00")
        following.end = .init(dateTime: "2026-11-02T11:00:00+01:00")
        following.summary = "Following series"
        return .splitSeries(eventID: master.id, etag: master.etag,
            originalStart: .init(dateTime: "2026-11-02T10:00:00+01:00"), followingEvent: following, resetExceptionsConfirmed: true)
    }
}

private actor RecoveryCalendarService: CalendarService {
    var remote: [String: [String: GoogleCalendarEvent]] = [:]
    var patchCount = 0
    var insertCount = 0
    var deleteCount = 0
    var moveCount = 0
    var importCount = 0
    var rejectMove = false
    var changePatch: Bool?
    var losePatch = false
    var loseInsert = false
    var loseMove = false
    var rejectInsert = false
    var changeDelete = false

    static func event(_ id: String) -> GoogleCalendarEvent {
        .init(rawValue: ["id": .string(id), "etag": .string("v1"), "iCalUID": .string(id + "@example.invalid"),
            "summary": .string("Meeting"), "start": .object(["dateTime": .string("2026-11-02T10:00:00+01:00")]),
            "end": .object(["dateTime": .string("2026-11-02T11:00:00+01:00")])])
    }
    static func series() -> GoogleCalendarEvent {
        var value = event("series")
        value.start = .init(dateTime: "2026-10-26T10:00:00+01:00")
        value.end = .init(dateTime: "2026-10-26T11:00:00+01:00")
        value.recurrence = ["RRULE:FREQ=WEEKLY;COUNT=5"]
        return value
    }
    func put(_ event: GoogleCalendarEvent, calendarID: String = "c") { remote[calendarID, default: [:]][event.id] = event }
    func failAfterPatch() { losePatch = true }
    func failAfterInsert() { loseInsert = true }
    func failAfterMove() { loseMove = true }
    func rejectNextMove() { rejectMove = true }
    func changeInstanceBeforePatch(cancelled: Bool) { changePatch = cancelled }
    func rejectNextInsert() { rejectInsert = true }
    func changeExceptionBeforeDelete() { changeDelete = true }
    func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage {
        .init(items: ["c", "other"].map { .init(rawValue: ["id": .string($0), "summary": .string($0), "accessRole": .string("owner"), "timeZone": .string("Europe/Vienna")]) })
    }
    func events(calendarID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
        .init(items: Array(remote[calendarID, default: [:]].values).filter { query.iCalUID == nil || $0.iCalUID == query.iCalUID }, nextSyncToken: "token")
    }
    func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
        guard let event = remote[calendarID]?[eventID] else { throw GmailError.notFound }
        return event
    }
    func instances(calendarID: String, eventID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
        .init(items: Array(remote[calendarID, default: [:]].values).filter { $0.recurringEventId == eventID })
    }
    func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String) async throws -> GoogleCalendarEvent {
        if rejectInsert { rejectInsert = false; throw GmailError.http(status: 400, reason: "invalid") }
        guard remote[calendarID]?[event.id] == nil else { throw GmailError.http(status: 409, reason: "duplicate") }
        insertCount += 1
        var saved = event; saved.etag = "inserted"; put(saved, calendarID: calendarID)
        if loseInsert { loseInsert = false; throw GmailError.http(status: 500, reason: "responseLost") }
        return saved
    }
    func importEvent(calendarID: String, event: GoogleCalendarEvent) async throws -> GoogleCalendarEvent {
        importCount += 1
        var saved = event; saved.id = "imported"; saved.etag = "imported"
        put(saved, calendarID: calendarID)
        return saved
    }
    func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
        var saved = try await event(calendarID: calendarID, eventID: eventID)
        if let cancelled = changePatch {
            changePatch = nil; saved.etag = "changed-instance"
            if cancelled { saved.status = "cancelled" }
            put(saved, calendarID: calendarID)
        }
        guard saved.etag == etag else { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        patchCount += 1
        for (key, value) in fields { saved.rawValue[key] = value == .null ? nil : value }
        saved.etag = "patched-\(patchCount)"; put(saved, calendarID: calendarID)
        if losePatch { losePatch = false; throw GmailError.http(status: 500, reason: "responseLost") }
        return saved
    }
    func deleteEvent(calendarID: String, eventID: String, etag: String?, sendUpdates: String) async throws {
        var value = try await event(calendarID: calendarID, eventID: eventID)
        if changeDelete { changeDelete = false; value.etag = "changed"; value.summary = "Exception changed elsewhere"; put(value, calendarID: calendarID) }
        guard value.etag == etag else { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        deleteCount += 1; remote[calendarID]?.removeValue(forKey: eventID)
    }
    func moveEvent(calendarID: String, eventID: String, destination: String, etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
        let value = try await event(calendarID: calendarID, eventID: eventID)
        guard value.etag == etag else { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        if rejectMove { rejectMove = false; throw GmailError.http(status: 400, reason: "rejectedMove") }
        moveCount += 1; remote[calendarID]?.removeValue(forKey: eventID); put(value, calendarID: destination)
        if loseMove { loseMove = false; throw GmailError.http(status: 500, reason: "responseLost") }
        return value
    }
}
