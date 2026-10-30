import Foundation
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

    private func response(source: String = "message", quote: String = "Meet July 15, 2031 at 14:00.") throws -> String {
        try AIJSON.object(["events": .array([.object([
            "title": .string("Planning"), "source_message_id": .string(source), "supporting_text": .string(quote),
            "superseded_message_ids": .array([]), "status": .string("proposed"),
            "start": .string("2031-07-15T14:00:00Z"), "end": .null, "all_day": .bool(false),
            "time_zone": .string("Etc/UTC"), "uncertainties": .array([.string("Choose a duration.")]),
        ])])]).jsonString()
    }
}

private struct EmailCalendarProvider: AIProvider {
    let text: String
    func models() async throws -> [AIModel] { [] }
    func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(AIResponse(output: [], text: text, toolCalls: [])))
            continuation.finish()
        }
    }
}
