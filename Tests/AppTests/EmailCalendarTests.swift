import Foundation
import GmailAPI
import MessageContent
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct EmailCalendarTests {
    private func message(_ id: String = "message") -> EmailCalendarMessage {
        EmailCalendarMessage(id: id, subject: "Planning", date: Date(timeIntervalSince1970: 1_700_000_000),
                             text: "Meet July 15, 2031 at 14:00.")
    }

    @Test func extractionRejectsInventedSourceAndEvidence() async throws {
        for (source, quote) in [("other-account-message", "Meet July 15, 2031 at 14:00."), ("message", "Not present in the message")] {
            let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response(source: source, quote: quote)),
                                                         model: "fixture", isScopeValid: { true })
            await #expect(throws: AIProviderError.invalidResponse) { try await service.extract(messages: [message()], timeZone: .current) }
        }
    }

    @Test func extractionChecksAccessAfterProviderSuspension() async throws {
        var checks = 0
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()), model: "fixture", isScopeValid: {
            checks += 1
            return checks == 1
        })
        await #expect(throws: AssistantError.self) { try await service.extract(messages: [message()], timeZone: .current) }
    }

    @Test func suggestionsRemainReviewableAndDismissalsSurviveRefresh() async throws {
        let model = EmailCalendarModel()
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()), model: "fixture", isScopeValid: { true })
        model.update(messages: [message()], addresses: [])
        await model.interpret(using: service)
        let item = try #require(model.visibleItems.first)
        #expect(item.kind == .proposed)
        #expect(item.event?.id.isEmpty == true)
        #expect(item.event?.attendees == nil)
        model.dismiss(item.id)
        await model.interpret(using: service)
        #expect(model.visibleItems.isEmpty)
        model.clearAIResults()
        #expect(model.items.allSatisfy { $0.kind == .detected })
    }

    @Test func cachedInterpretationRejectsChangedSourceAndRevocationRestoresLocalDetection() async throws {
        let first = EmailCalendarModel()
        first.update(messages: [message()], addresses: [])
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()), model: "fixture", isScopeValid: { true })
        await first.interpret(using: service)
        let cached = try #require(first.cachedInterpretation)
        let reopened = EmailCalendarModel()
        reopened.update(messages: [message()], addresses: [])
        #expect(reopened.restoreInterpretation(cached, for: first.revision))
        #expect(reopened.items.first?.kind == .proposed)
        reopened.clearAIResults()
        #expect(reopened.cachedInterpretation == nil)
        #expect(reopened.items.allSatisfy { $0.kind == .detected })
        reopened.update(messages: [EmailCalendarMessage(id: "message", subject: "Changed", date: message().date, text: "No meeting.")], addresses: [])
        #expect(!reopened.restoreInterpretation(cached, for: first.revision))
    }

    @Test func interpretationReplacesLocalDetectionAndDropsUndatedProposals() async throws {
        for text in [#"{"events": []}"#, try response(start: nil)] {
            let model = EmailCalendarModel()
            model.update(messages: [message()], addresses: [])
            #expect(model.items.first?.kind == .detected)
            await model.interpret(using: EmailCalendarExtractionService(provider: EmailCalendarProvider(text: text), model: "fixture", isScopeValid: { true }))
            #expect(model.cachedInterpretation != nil)
            #expect(model.items.isEmpty)
        }
    }

    @Test func replyAddressChangeKeepsInterpretation() async throws {
        let model = EmailCalendarModel()
        model.update(messages: [message()], addresses: [])
        await model.interpret(using: EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()), model: "fixture", isScopeValid: { true }))
        model.update(messages: [message()], addresses: ["river@example.invalid"])
        #expect(model.items.map(\.kind) == [.proposed])
        #expect(model.cachedInterpretation != nil)
    }

    @Test func replyAddressChangeKeepsRunningInterpretation() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let model = EmailCalendarModel()
        model.update(messages: [message()], addresses: [])
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response(), gate: gate.stream),
                                                     model: "fixture", isScopeValid: { true })
        let interpretation = Task { await model.interpret(using: service) }
        for _ in 0..<10 where !model.isInterpreting { await Task.yield() }
        #expect(model.isInterpreting)
        model.update(messages: [message()], addresses: ["river@example.invalid"])
        gate.continuation.finish()
        await interpretation.value
        #expect(model.items.map(\.kind) == [.proposed])
    }

    @Test func localDetectionSkipsPromotionsAndEndedEvents() {
        var promotion = message()
        promotion.allowsDateDetection = false
        let model = EmailCalendarModel()
        model.update(messages: [message()], addresses: [])
        #expect(model.items.count == 1)
        model.update(messages: [promotion], addresses: [])
        #expect(model.items.isEmpty)
        let later = EmailCalendarModel()
        later.update(messages: [message()], addresses: [], now: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(later.items.isEmpty)
    }

    @Test func cachedCancellationReplacesEarlierSuggestionAndRejectsInventedRelatedSource() throws {
        let model = EmailCalendarModel()
        let cancellation = EmailCalendarMessage(id: "later", subject: "Cancelled", date: message().date.addingTimeInterval(60), text: "The planning meeting is cancelled.")
        model.update(messages: [message(), cancellation], addresses: [])
        var item = EmailCalendarItem(id: "interpreted:fixture", messageID: "later", title: "Planning",
            evidence: cancellation.text, kind: .cancelled, relatedMessageIDs: ["message"])
        #expect(model.restoreInterpretation([item], for: model.revision))
        #expect(model.items.count == 1)
        #expect(model.items.first?.kind == .cancelled)
        #expect(model.items.first?.canReview == false)
        item.relatedMessageIDs = ["different-account-message"]
        #expect(!model.restoreInterpretation([item], for: model.revision))
    }

    @Test func eventPresentationKeepsCivilDatesAndExclusiveAllDayEnds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var event = GoogleCalendarEvent(summary: "Workshop")
        event.start = CalendarDateTime(date: "2031-07-15", timeZone: "Europe/Vienna")
        event.end = CalendarDateTime(date: "2031-07-18", timeZone: "Europe/Vienna")
        let item = EmailCalendarItem(id: "event", messageID: "message", title: "Workshop", evidence: "", kind: .detected, event: event)
        let presentation = EmailCalendarPresentation(item: item, calendar: calendar)
        #expect(calendar.component(.day, from: try #require(presentation.start)) == 15)
        #expect(calendar.component(.day, from: try #require(presentation.inclusiveEnd)) == 17)
        #expect(presentation.day == "15")
        #expect(presentation.dateLine.contains("Jul 17, 2031"))
        #expect(!presentation.dateLine.contains("Jul 18"))
    }

    @Test func eventPresentationUsesSelectedZoneForTileAndTimeAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        var event = GoogleCalendarEvent(summary: "Late call")
        event.start = CalendarDateTime(dateTime: "2031-07-15T23:30:00Z")
        event.end = CalendarDateTime(dateTime: "2031-07-16T00:30:00Z")
        var item = EmailCalendarItem(id: "event", messageID: "message", title: "Late call", evidence: "", kind: .proposed, event: event)
        let presentation = EmailCalendarPresentation(item: item, calendar: calendar)
        #expect(presentation.day == "16")
        #expect(presentation.dateLine.contains("16 Jul 2031"))
        #expect(presentation.dateLine.contains("01:30"))
        #expect(presentation.dateLine.contains("02:30"))
        item.event = nil
        let undated = EmailCalendarPresentation(item: item, calendar: calendar)
        #expect(undated.day == nil)
        #expect(undated.inclusiveEnd == nil)
        #expect(undated.dateLine == "Date to be confirmed")
    }

    @Test func eventPresentationFallsBackFromEmptyCalendarLocaleToUserLocale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "")
        var event = GoogleCalendarEvent(summary: "Workshop")
        event.start = CalendarDateTime(date: "2031-07-15")
        let item = EmailCalendarItem(id: "event", messageID: "message", title: "Workshop", evidence: "", kind: .detected, event: event)
        let unspecified = EmailCalendarPresentation(item: item, calendar: calendar)
        calendar.locale = .autoupdatingCurrent
        let localized = EmailCalendarPresentation(item: item, calendar: calendar)
        #expect(unspecified.month == localized.month)
        #expect(unspecified.dateLine == localized.dateLine)
    }

    @Test func collapsedEventOrderPrioritizesCurrentChangesOverOldInvitations() {
        let old = EmailCalendarItem(id: "old", messageID: "early", title: "Planning", evidence: "", kind: .invitation, isOutdated: true)
        let ordinary = EmailCalendarItem(id: "ordinary", messageID: "latest", title: "Another event", evidence: "", kind: .proposed)
        let cancelled = EmailCalendarItem(id: "cancelled", messageID: "later", title: "Planning", evidence: "", kind: .cancelled)
        let updated = EmailCalendarItem(id: "updated", messageID: "latest", title: "Rescheduled", evidence: "", kind: .updated)
        let messages = ["early", "later", "latest"].enumerated().map { index, id in
            EmailCalendarMessage(id: id, subject: "Planning", date: Date(timeIntervalSince1970: Double(index)), text: "")
        }
        let ordered = EmailCalendarPresentation.ordered([old, ordinary, cancelled, updated], messages: messages)
        #expect(ordered.map(\.id) == ["updated", "cancelled", "ordinary", "old"])
    }

    @Test func eventBadgesDistinguishSuggestionsSavedEventsAndChanges() {
        var event = GoogleCalendarEvent(summary: "Planning")
        event.start = CalendarDateTime(date: "2031-07-15")
        var item = EmailCalendarItem(id: "event", messageID: "message", title: "Planning", evidence: "", kind: .proposed, event: event)
        func badge() -> EmailCalendarPresentation.Badge { EmailCalendarPresentation(item: item, calendar: .current).badge }
        #expect(badge().symbol == "questionmark")
        item.existingEventID = "saved"
        #expect(badge().symbol == "checkmark")
        item.calendarAnswer = .declined
        #expect(badge().symbol == "xmark")
        #expect(badge().tone == .negative)
        item.calendarAnswer = .accepted
        item.hasAmbiguousMatch = true
        #expect(badge().tone == .caution)
        item.hasAmbiguousMatch = false
        item.uncertainties = ["Check the time zone."]
        #expect(badge().symbol == "questionmark")
        item.uncertainties = []
        item.kind = .updated
        #expect(badge().symbol == "arrow.triangle.2.circlepath")
        item.kind = .cancelled
        #expect(badge().symbol == "xmark")
        item.isOutdated = true
        #expect(badge().symbol == "clock.arrow.circlepath")
    }

    @Test func responseBadgesDoNotPresentMixedOrDeclinedAnswersAsAccepted() throws {
        var invitation = try Invitation(data: Data(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Tern Test//EN\r\nMETHOD:REPLY\r\n" +
            "BEGIN:VEVENT\r\nUID:badge-test\r\nDTSTAMP:20310701T090000Z\r\nDTSTART:20310715T090000Z\r\n" +
            "ATTENDEE;CN=River;PARTSTAT=ACCEPTED:mailto:river@example.invalid\r\n" +
            "ATTENDEE;CN=Sky;PARTSTAT=ACCEPTED:mailto:sky@example.invalid\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").utf8))
        var item = EmailCalendarItem(id: "response", messageID: "message", title: "Planning", evidence: "", kind: .response, invitation: invitation)
        #expect(EmailCalendarPresentation(item: item, calendar: .current).badge.tone == .positive)
        invitation.attendees[1].status = .declined
        item.invitation = invitation
        let mixed = EmailCalendarPresentation(item: item, calendar: .current)
        #expect(mixed.badge.symbol == "questionmark")
        #expect(mixed.badge.tone == .caution)
        #expect(mixed.responseLines.count == 2)
        invitation.attendees[0].status = .declined
        item.invitation = invitation
        #expect(EmailCalendarPresentation(item: item, calendar: .current).badge.symbol == "xmark")
    }

    private func response(source: String = "message", quote: String = "Meet July 15, 2031 at 14:00.",
                          start: String? = "2031-07-15T14:00:00Z") throws -> String {
        try AIJSON.object(["events": .array([.object([
            "title": .string("Planning"), "source_message_id": .string(source), "supporting_text": .string(quote),
            "superseded_message_ids": .array([]), "status": .string("proposed"),
            "start": start.map(AIJSON.string) ?? .null, "end": .null, "all_day": .bool(false),
            "time_zone": .string("Etc/UTC"), "uncertainties": .array([.string("Choose a duration.")]),
        ])])]).jsonString()
    }
}

private struct EmailCalendarProvider: AIProvider {
    let text: String
    var gate: AsyncStream<Void>? = nil
    func models() async throws -> [AIModel] { [] }
    func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let response = AIResponse(output: [], text: text, toolCalls: [])
            guard let gate else {
                continuation.yield(.completed(response))
                continuation.finish()
                return
            }
            Task {
                for await _ in gate { break }
                continuation.yield(.completed(response))
                continuation.finish()
            }
        }
    }
}
