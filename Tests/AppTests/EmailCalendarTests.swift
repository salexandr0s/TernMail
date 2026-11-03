import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct EmailCalendarTests {
    @Test func calendarActionsReturnTheirOwnFailuresWithoutReplacingAnotherNotice() async throws {
        let suite = "tern.email-calendar.failures." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(app: nil, defaults: defaults)
        model.store = try CalendarStore.inMemory()
        model.errorMessage = "An earlier calendar notice"
        let item = EmailCalendarItem(id: "interpreted:planning", messageID: "message", title: "Planning call",
            evidence: "Meet to plan the launch.", kind: .proposed,
            event: GoogleCalendarEvent(summary: "Planning call", start: CalendarDateTime(date: "2031-07-15")))
        let key = ThreadKey(accountID: "account", threadID: "thread")

        await #expect(throws: CalendarModelError.self) { try await model.reviewEmailSuggestion(item, key: key) }
        await #expect(throws: CalendarModelError.self) {
            try await model.openEventEditor(accountID: "account", calendarID: "calendar", eventID: "event")
        }
        #expect(model.errorMessage == "An earlier calendar notice")
        #expect(model.editor == nil)

        let cancelled = Task { try await model.reviewEmailSuggestion(item, key: key) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await #expect(throws: CancellationError.self) {
            try await model.openEventEditor(accountID: "account", calendarID: "calendar", eventID: "event", isAuthorized: { false })
        }
        #expect(model.errorMessage == "An earlier calendar notice")
    }

    @Test func simultaneousInterpretationsShareInferenceWhenOneReaderCancels() async throws {
        let provider = SharedEmailCalendarProvider()
        let requests = AssistantSharedRequests<EmailCalendarExtractionService.RequestKey, [EmailCalendarItem]>()
        let service = sharedService(provider: provider, requests: requests)
        let first = Task { try await service.extract(messages: [message()], timeZone: .gmt) }
        defer { first.cancel() }
        try await provider.waitForRequests(1)
        let second = Task { try await service.extract(messages: [message()], timeZone: .gmt) }
        defer { second.cancel() }
        try await waitForJoinedReaders(2, service: service, requests: requests)

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await provider.requestCount == 1)
        #expect(await provider.cancellationCount == 0)
        await provider.complete(text: try response())
        #expect(try await second.value.map(\.title) == ["Planning"])
    }

    @Test(arguments: ["source", "timeZone", "model", "access"])
    func interpretationSharingKeepsSourceModelZoneAndAccessSeparate(change: String) async throws {
        let provider = SharedEmailCalendarProvider()
        let requests = AssistantSharedRequests<EmailCalendarExtractionService.RequestKey, [EmailCalendarItem]>()
        let service = sharedService(provider: provider, requests: requests)
        let first = Task { try await service.extract(messages: [message()], timeZone: .gmt) }
        defer { first.cancel() }
        try await provider.waitForRequests(1)

        var otherService = service
        var otherMessage = message()
        var zone = TimeZone.gmt
        switch change {
        case "source": otherMessage.forwardedText = "Confirmed flight July 15, 2031."
        case "timeZone": zone = try #require(TimeZone(identifier: "Europe/Vienna"))
        case "model": otherService = sharedService(provider: provider, requests: requests, model: "other-model")
        default: otherService = sharedService(provider: provider, requests: requests, accessRevision: 2)
        }
        let changedService = otherService, changedMessage = otherMessage, changedZone = zone
        let second = Task { try await changedService.extract(messages: [changedMessage], timeZone: changedZone) }
        defer { second.cancel() }
        try await provider.waitForRequests(2)
        await provider.complete(text: try response())
        _ = try await (first.value, second.value)
        #expect(await provider.requestCount == 2)
    }

    @Test func sharedInterpretationRechecksEachReadersAccessBeforeReturning() async throws {
        let provider = SharedEmailCalendarProvider()
        let requests = AssistantSharedRequests<EmailCalendarExtractionService.RequestKey, [EmailCalendarItem]>()
        let firstService = sharedService(provider: provider, requests: requests)
        var secondHasAccess = true
        var secondService = sharedService(provider: provider, requests: requests)
        secondService = EmailCalendarExtractionService(provider: provider, model: secondService.model,
            requests: requests, requestIdentity: secondService.requestIdentity, isScopeValid: { secondHasAccess })
        let first = Task { try await firstService.extract(messages: [message()], timeZone: .gmt) }
        defer { first.cancel() }
        try await provider.waitForRequests(1)
        let joinedService = secondService
        let second = Task { try await joinedService.extract(messages: [message()], timeZone: .gmt) }
        defer { second.cancel() }
        try await waitForJoinedReaders(2, service: firstService, requests: requests)
        secondHasAccess = false
        await provider.complete(text: try response())
        #expect(try await first.value.count == 1)
        await #expect(throws: AssistantError.self) { try await second.value }
        #expect(await provider.requestCount == 1)
    }

    private func sharedService(provider: any AIProvider,
                               requests: AssistantSharedRequests<EmailCalendarExtractionService.RequestKey, [EmailCalendarItem]>,
                               model: String = "fixture", accessRevision: Int = 1) -> EmailCalendarExtractionService {
        let scope = AssistantScopeSnapshot(accountIDs: ["a"], threadIDs: nil,
            accountInstances: ["a": "instance"], connectionRevision: 1, canUsePlan: true)
        return EmailCalendarExtractionService(provider: provider, model: model, requests: requests,
            requestIdentity: .init(scope: scope, thread: .init(accountID: "a", threadID: "thread"), accessRevision: accessRevision),
            isScopeValid: { true })
    }

    private func waitForJoinedReaders(_ count: Int, service: EmailCalendarExtractionService,
                                     requests: AssistantSharedRequests<EmailCalendarExtractionService.RequestKey, [EmailCalendarItem]>) async throws {
        let identity = try #require(service.requestIdentity)
        let key = EmailCalendarExtractionService.RequestKey(identity: identity, model: service.model,
            sourceRevision: EmailCalendarModel.fingerprint([message()], timeZone: .gmt))
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while requests.waiterCount(for: key) < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(requests.waiterCount(for: key) == count)
    }

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

    @Test func extractionAndCachedInterpretationRejectQuotedAndEmptyEvidence() async throws {
        let quote = "Meet July 15, 2031 at 14:00."
        let sources = [
            EmailCalendarMessage(id: "message", subject: "Planning", date: message().date,
                text: "No meeting planned.\n> Meet July 15, 2031 at 14:00."),
            EmailCalendarMessage(id: "message", subject: "Planning", date: message().date,
                text: "Sharing an old message.\n---------- Forwarded message ---------\nMeet July 15, 2031 at 14:00."),
        ]
        for source in sources {
            let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response(quote: quote)),
                                                         model: "fixture", isScopeValid: { true })
            await #expect(throws: AIProviderError.invalidResponse) { try await service.extract(messages: [source], timeZone: .current) }
            let model = EmailCalendarModel()
            model.update(messages: [source], addresses: [])
            let cached = EmailCalendarItem(id: "interpreted:fixture", messageID: source.id, title: "Planning",
                evidence: quote, kind: .proposed)
            #expect(!model.restoreInterpretation([cached], for: model.revision))
            #expect(!source.supportsCalendarEvidence(" \n\t"))
        }
    }

    @Test func interpretedPromotionInvitationAcceptsWrappedSourceEvidence() async throws {
        let source = EmailCalendarMessage(id: "sale", subject: "Your private sale invitation", date: message().date,
            text: "Private sale invitation: July 15,\n2031 at\t14:00.", allowsDateDetection: false)
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response(source: source.id,
            quote: "Private sale invitation: July 15, 2031 at 14:00.", title: "Private sale")),
            model: "fixture", isScopeValid: { true })
        let model = EmailCalendarModel()
        model.update(messages: [source], addresses: [])
        #expect(model.items.isEmpty)
        await model.interpret(using: service)
        let proposal = try #require(model.items.first)
        #expect(proposal.kind == .proposed)
        #expect(proposal.title == "Private sale")
        #expect(proposal.canReview)
        let reopened = EmailCalendarModel()
        reopened.update(messages: [source], addresses: [])
        let cached = try #require(model.cachedInterpretation)
        #expect(reopened.restoreInterpretation(cached, for: model.revision))
        #expect(reopened.items == model.items)
    }

    @Test func forwardedBookingPreservesWrapperSourceAndWarnsWithoutUsingWrapperClock() async throws {
        let body = "Confirmed flight departs July 15, 2031 at 14:00."
        let source = EmailCalendarMessage(id: "forward", subject: "Fw: Booking confirmation", date: message().date,
            text: "Here is my booking.", dateHeaderOffset: -28_800, forwardedText: body)
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response(source: source.id,
            quote: body, timeZone: nil, title: "Flight")), model: "fixture", isScopeValid: { true })
        let model = EmailCalendarModel()
        model.update(messages: [source], addresses: [], timeZone: try #require(TimeZone(identifier: "Europe/Paris")))
        #expect(model.items.isEmpty)
        await model.interpret(using: service)
        let item = try #require(model.items.first)
        #expect(item.messageID == source.id)
        #expect(item.evidence == body)
        #expect(item.canReview)
        #expect(item.uncertainties.contains(EmailCalendarMessage.forwardedEvidenceWarning))
        #expect(item.uncertainties.contains("Confirm the time zone for this forwarded booking."))
        #expect(!item.uncertainties.contains { $0.hasPrefix("Check the time zone. The sender's clock") })
        let cached = try #require(model.cachedInterpretation)
        let reopened = EmailCalendarModel()
        reopened.update(messages: [source], addresses: [], timeZone: try #require(TimeZone(identifier: "Europe/Paris")))
        #expect(reopened.restoreInterpretation(cached, for: model.revision))
        var withoutWarning = item
        withoutWarning.uncertainties.removeAll { $0 == EmailCalendarMessage.forwardedEvidenceWarning }
        #expect(!reopened.restoreInterpretation([withoutWarning], for: model.revision))
        var changedSource = source
        changedSource.forwardedText = nil
        #expect(EmailCalendarModel.fingerprint([changedSource], timeZone: .current)
            != EmailCalendarModel.fingerprint([source], timeZone: .current))
    }

    @Test func forwardedBookingRejectsInferredDatesAndInventedEvidence() async throws {
        let explicit = "Confirmed flight departs July 15, 2031 at 14:00."
        let cases: [(body: String, quote: String, start: String?)] = [
            ("Confirmed flight departs July 15 at 14:00.", "Confirmed flight departs July 15 at 14:00.", "2031-07-15T14:00:00Z"),
            ("Confirmed flight departs tomorrow at 14:00.", "Confirmed flight departs tomorrow at 14:00.", "2031-07-15T14:00:00Z"),
            (explicit, "Confirmed flight departs July 16, 2031 at 14:00.", "2031-07-16T14:00:00Z"),
            (explicit, explicit, "2031-07-16T14:00:00Z"),
            (explicit, explicit, nil),
        ]
        for example in cases {
            let source = EmailCalendarMessage(id: "forward", subject: "Fw: Booking confirmation", date: message().date,
                text: "Here is my booking.", forwardedText: example.body)
            let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response(source: source.id,
                quote: example.quote, start: example.start)), model: "fixture", isScopeValid: { true })
            await #expect(throws: AIProviderError.invalidResponse) { try await service.extract(messages: [source], timeZone: .current) }
            let model = EmailCalendarModel()
            model.update(messages: [source], addresses: [])
            let event = GoogleCalendarEvent(summary: "Flight", start: example.start.map { CalendarDateTime(dateTime: $0) })
            let cached = EmailCalendarItem(id: "interpreted:forward", messageID: source.id, title: "Flight",
                evidence: example.quote, kind: .proposed, event: event,
                uncertainties: [EmailCalendarMessage.forwardedEvidenceWarning])
            #expect(!model.restoreInterpretation([cached], for: model.revision))
        }
    }

    @Test func failedInterpretationCanRetryWithoutLosingLocalCandidates() async throws {
        let model = EmailCalendarModel()
        model.update(messages: [message()], addresses: [])
        let local = model.items
        #expect(!local.isEmpty)
        await model.interpret(using: EmailCalendarExtractionService(provider: FailedEmailCalendarProvider(),
            model: "fixture", isScopeValid: { true }))
        #expect(model.items == local)
        #expect(model.interpretationError != nil)
        #expect(!model.isInterpreting)
        #expect(model.cachedInterpretation == nil)
        await model.interpret(using: EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()),
            model: "fixture", isScopeValid: { true }))
        #expect(model.items.map(\.kind) == [.proposed])
        #expect(model.interpretationError == nil)
        #expect(!model.isInterpreting)
        #expect(model.cachedInterpretation != nil)
    }

    @Test func extractionChecksAccessAfterProviderSuspension() async throws {
        var checks = 0
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()), model: "fixture", isScopeValid: {
            checks += 1
            return checks == 1
        })
        await #expect(throws: AssistantError.self) { try await service.extract(messages: [message()], timeZone: .current) }
    }

    @Test(arguments: [false, true])
    func cancellationAtExtractionCompletionClearsProgressAndAllowsRetry(scopeRemainsValid: Bool) async throws {
        let model = EmailCalendarModel()
        model.update(messages: [message()], addresses: [])
        let local = model.items
        var pending: Task<Void, Never>?
        var checks = 0
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()),
            model: "fixture", isScopeValid: {
                checks += 1
                if checks == 3 { pending?.cancel() }
                return checks != 3 || scopeRemainsValid
            })
        pending = Task { await model.interpret(using: service) }
        await pending?.value
        #expect(pending?.isCancelled == true)
        #expect(!model.isInterpreting)
        #expect(model.interpretationError == nil)
        #expect(model.items == local)
        #expect(model.cachedInterpretation == nil)
        await model.interpret(using: EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response()),
            model: "fixture", isScopeValid: { true }))
        #expect(model.items.map(\.kind) == [.proposed])
        #expect(model.cachedInterpretation != nil)
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

    @Test func onlyASenderInAnotherZoneGetsATimeZoneWarning() async throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        var elsewhere = message()
        elsewhere.dateHeaderOffset = -28_800
        let cases: [(EmailCalendarMessage, [String])] = [
            (message(), []), (elsewhere, ["Check the time zone. The sender's clock is 9 hours behind yours."]),
        ]
        let service = EmailCalendarExtractionService(provider: EmailCalendarProvider(text: try response(timeZone: nil)),
                                                     model: "fixture", isScopeValid: { true })
        // One model for both, so an offset that arrives for mail it already read must refresh the cards.
        let model = EmailCalendarModel()
        for (source, expected) in cases {
            model.update(messages: [source], addresses: [], timeZone: paris)
            let extracted = try await service.extract(messages: [source], timeZone: paris)
            for item in [try #require(model.items.first), try #require(extracted.first)] {
                #expect(item.uncertainties.filter { $0.hasPrefix("Check the time zone") } == expected)
            }
        }
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
                          start: String? = "2031-07-15T14:00:00Z", timeZone: String? = "Etc/UTC",
                          title: String = "Planning") throws -> String {
        try AIJSON.object(["events": .array([.object([
            "title": .string(title), "source_message_id": .string(source), "supporting_text": .string(quote),
            "superseded_message_ids": .array([]), "status": .string("proposed"),
            "start": start.map(AIJSON.string) ?? .null, "end": .null, "all_day": .bool(false),
            "time_zone": timeZone.map(AIJSON.string) ?? .null, "uncertainties": .array([.string("Choose a duration.")]),
        ])])]).jsonString()
    }
}

private struct FailedEmailCalendarProvider: AIProvider {
    func models() async throws -> [AIModel] { [] }
    func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: AIProviderError.streamInterrupted) }
    }
}

private actor SharedEmailCalendarProvider: AIProvider {
    private var responses: [AsyncThrowingStream<AIEvent, any Error>.Continuation] = []
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0

    func models() async throws -> [AIModel] { [] }

    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination { Task { await self.recordCancellation() } }
            }
            Task { await self.start(continuation) }
        }
    }

    func waitForRequests(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while requestCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(requestCount >= count)
    }

    func complete(text: String) {
        let response = AIResponse(output: [], text: text, toolCalls: [])
        let completed = responses
        responses.removeAll()
        for continuation in completed {
            continuation.yield(.completed(response))
            continuation.finish()
        }
    }

    private func start(_ continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        requestCount += 1
        responses.append(continuation)
    }

    private func recordCancellation() { cancellationCount += 1 }
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
