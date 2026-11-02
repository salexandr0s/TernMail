import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct AssistantEventResultTests {
    @Test func allDayCardsKeepCivilDatesAndAnInclusiveDisplayEnd() throws {
        var event = GoogleCalendarEvent(summary: "Conference")
        event.start = .init(date: "2031-11-05")
        event.end = .init(date: "2031-11-08")
        let result = AssistantEventResult(source: source, event: event)
        #expect(result.canAddToCalendar)
        for identifier in ["Pacific/Honolulu", "Europe/Vienna", "Pacific/Auckland"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: identifier))
            let display = result.presentation(calendar: calendar)
            #expect(calendar.component(.day, from: try #require(display.start)) == 5)
            #expect(calendar.component(.day, from: try #require(display.inclusiveEnd)) == 7)
        }
    }

    @Test func mailCandidatesRequireDatesAndCannotCarryInvitationRecipients() {
        var event = timedEvent()
        event.id = "provider-id"
        event.attendees = [.init(email: "guest@example.invalid")]
        event.recurrence = ["RRULE:FREQ=DAILY"]
        let result = AssistantEventResult(source: source, event: event)
        #expect(result.canAddToCalendar)
        #expect(result.event.id.isEmpty)
        #expect(result.event.attendees == nil)
        #expect(result.event.recurrence == nil)
        #expect(result.emailItem.invitation == nil)

        var sameInstant = event
        sameInstant.start = .init(dateTime: "2031-11-05T15:00:00+01:00")
        #expect(AssistantEventResult(source: source, event: sameInstant).id == result.id)
        event.start = nil
        #expect(!AssistantEventResult(source: source, event: event).canAddToCalendar)
        event.start = .init(dateTime: "2031-11-05T14:00:00", timeZone: "Europe/Vienna")
        #expect(!AssistantEventResult(source: source, event: event).canAddToCalendar)
        event.start = .init(dateTime: "2031-11-05T15:30:00Z")
        #expect(!AssistantEventResult(source: source, event: event).canAddToCalendar)
        event.start = .init(date: "2031-02-30")
        event.end = .init(date: "2031-03-01")
        #expect(!AssistantEventResult(source: source, event: event).canAddToCalendar)

        let calendarSource = AssistantSource(accountID: "a", calendarID: "work", eventID: "existing", title: "Conference")
        let existing = AssistantEventResult(source: calendarSource, event: timedEvent())
        #expect(existing.isExistingEvent)
        #expect(!existing.canAddToCalendar)
        #expect(existing.id == calendarSource.id)
        #expect(existing.emailItem.existingEventID == "existing")
    }

    @Test func reviewPersistsProvenanceWithoutSavingAndPreservesUserCorrections() async throws {
        let fixture = try fixture()
        defer { fixture.clean() }
        var event = timedEvent()
        event.end = nil
        let result = AssistantEventResult(source: source, event: event, evidence: "Meet November 5 at 14:00 UTC.")
        try await fixture.model.reviewAssistantEvent(result, isAuthorized: { true })
        let recordID = "a:" + result.id
        let firstDraft = try #require(fixture.model.editor)
        #expect(firstDraft.sourceID == recordID)
        #expect(firstDraft.event.endDate?.timeIntervalSince(try #require(firstDraft.event.startDate)) == 1800)
        #expect(try await fixture.store.operations(accountID: "a").isEmpty)
        var record = try #require(try await fixture.store.suggestion(id: recordID))
        #expect(record.threadID == "thread")
        #expect(record.messageID == "message")
        #expect(record.sourceText == result.evidence)
        #expect(record.operationID == nil)

        fixture.model.editor?.event.summary = "Unsaved change"
        try await fixture.model.reviewAssistantEvent(result, isAuthorized: { true })
        #expect(fixture.model.editor?.id == firstDraft.id)
        #expect(fixture.model.editor?.event.summary == "Unsaved change")

        fixture.model.editor = nil
        record.isUserEdited = true
        record.event.summary = "Corrected title"
        record.event.location = "Room 4"
        try await fixture.store.saveSuggestion(record, preservingCorrections: false)
        try await fixture.model.reviewAssistantEvent(result, isAuthorized: { true })
        #expect(fixture.model.editor?.event.summary == "Corrected title")
        #expect(fixture.model.editor?.event.location == "Room 4")
        #expect(try await fixture.store.suggestion(id: recordID)?.isUserEdited == true)
    }

    @Test func revokedAccessStopsReviewAfterTheFirstStoreRead() async throws {
        let fixture = try fixture()
        defer { fixture.clean() }
        let result = AssistantEventResult(source: source, event: timedEvent())
        var checks = 0
        await #expect(throws: AssistantError.self) {
            try await fixture.model.reviewAssistantEvent(result, isAuthorized: {
                checks += 1
                return checks == 1
            })
        }
        #expect(fixture.model.editor == nil)
        #expect(try await fixture.store.suggestions(accountID: "a", threadID: "thread").isEmpty)
        #expect(fixture.model.interactionsInFlight.isEmpty)
    }

    @Test func aQueuedReceiptReopensTheSameCalendarAction() async throws {
        let fixture = try fixture()
        defer { fixture.clean() }
        let result = AssistantEventResult(source: source, event: timedEvent())
        let sourceID = "a:" + result.id
        let operation = CalendarOperation(accountID: "a", calendarID: "work", mutation: .create(result.event),
            status: .queued, sourceSuggestionID: sourceID)
        try await fixture.store.saveOperation(operation)
        try await fixture.store.saveSuggestion(.init(id: sourceID, accountID: "a", threadID: "thread", messageID: "message",
            sourceRevision: result.id, event: result.event, sourceText: "Meet November 5.", isUserEdited: true,
            operationID: operation.id))
        try await fixture.model.reviewAssistantEvent(result, isAuthorized: { true })
        #expect(fixture.model.editor?.operationID == operation.id)
        #expect(fixture.model.editor?.sourceID == sourceID)
        #expect(try await fixture.store.operations(accountID: "a").count == 1)
    }

    @Test func anUnrelatedWritableCalendarCannotReceiveTheMailEvent() async throws {
        let fixture = try fixture()
        defer { fixture.clean() }
        fixture.model.calendars[0].accountID = "b"
        let result = AssistantEventResult(source: source, event: timedEvent())
        await #expect(throws: CalendarModelError.self) {
            try await fixture.model.reviewAssistantEvent(result, isAuthorized: { true })
        }
        #expect(fixture.model.editor == nil)
        #expect(try await fixture.store.suggestions(accountID: "a", threadID: "thread").isEmpty)
    }

    private var source: AssistantSource {
        .init(accountID: "a", threadID: "thread", messageID: "message", partID: nil, title: "Planning")
    }

    private func timedEvent() -> GoogleCalendarEvent {
        var event = GoogleCalendarEvent(summary: "Planning meeting")
        event.start = .init(dateTime: "2031-11-05T14:00:00Z")
        event.end = .init(dateTime: "2031-11-05T15:00:00Z")
        return event
    }

    private func fixture() throws -> Fixture {
        let domain = "AssistantEventResultTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let model = CalendarModel(app: nil, defaults: defaults)
        let store = try CalendarStore.inMemory()
        model.store = store
        model.calendars = [.init(entry: .init(id: "work", summary: "Work", accessRole: "owner"), accountID: "a", accountName: "Work")]
        return Fixture(model: model, store: store, defaults: defaults, domain: domain)
    }

    private struct Fixture {
        let model: CalendarModel
        let store: CalendarStore
        let defaults: UserDefaults
        let domain: String
        func clean() { defaults.removePersistentDomain(forName: domain) }
    }
}
