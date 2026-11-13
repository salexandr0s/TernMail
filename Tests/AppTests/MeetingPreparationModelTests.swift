import Foundation
import GmailAPI
@testable import MailStore
import MessageContent
import Observation
import SyncEngine
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct MeetingPreparationModelTests {
    @Test func acceptedCorrectionsAndClosedWorkReplaceExactAndRephrasedSuggestions() async throws {
        let fixture = try await MeetingModelFixture()
        let report = try fixture.report(fixture.candidate("a", "thread"))
        let request = try #require(FollowUpSuggestionRequest.make(report.report.summary.openTasks[0], report: report.report, detail: report.detail))
        for (id, messageID, status, key) in [("exact", "m1", CommitmentStatus.completed, Optional(request.acceptanceKey)),
                                           ("overlap", "m2", .dismissed, nil)] {
            _ = try await fixture.store.createCommitment(.init(accountID: "a", id: id, threadID: "thread", sourceMessageID: messageID,
                sourceMessageDate: fixture.date, sourceSubject: "Orion", title: "Corrected \(id)", ownerName: "Corrected person",
                direction: .waitingFor, status: status, acceptanceKey: key))
        }
        let model = fixture.model()
        defer { model.stop() }
        await model.start()
        let section = try #require(model.sections.first)
        #expect(section.trackedWork.map(\.record.title).sorted() == ["Corrected exact", "Corrected overlap"])
        #expect(Set(section.trackedWork.map(\.record.status)) == [.completed, .dismissed])
        #expect(section.suppressedSuggestionCount == 1)
        #expect(section.suggestions.map(\.request.title) == ["Task m3"])
        model.trackSuggestion(try #require(section.suggestions.first))
        #expect(fixture.accepted?.source.messageID == "m3")
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).count == 2)
    }

    @Test func failedFreshEventReadKeepsNativeSourcesButNeverCallsProviderSession() async throws {
        let fixture = try await MeetingModelFixture()
        fixture.eventReadFails = true
        let model = fixture.model()
        defer { model.stop() }
        await model.start()
        #expect(model.state == .unavailable)
        #expect(model.isStale)
        #expect(model.sources.map(\.key.threadID) == ["thread"])
        #expect(fixture.sessionCount == 0)
        #expect(fixture.summaryCount == 0)
        model.openConversation(.init(accountID: "a", threadID: "thread"))
        #expect(fixture.opened?.messageID == "m1")
    }

    @Test func explicitCrossAccountSourceRestoresWithoutEventOrSearchProvenance() async throws {
        let fixture = try await MeetingModelFixture()
        fixture.ids = ["a", "b"]
        let model = fixture.model()
        defer { model.stop() }
        await model.start()
        let key = ThreadKey(accountID: "b", threadID: "manual")
        await model.include(key)
        #expect(model.sections.contains { $0.candidate.thread == key })
        await model.exclude(key)
        #expect(!model.sections.contains { $0.candidate.thread == key })
        #expect(model.sources.first { $0.key == key }?.isExcluded == true)
        await model.restore(key)
        #expect(model.sections.contains { $0.candidate.thread == key })
        #expect(model.sources.first { $0.key == key }?.isExplicitlyIncluded == true)
        let occurrence = try #require(model.occurrence)
        let saved = try await fixture.store.meetingPreparationPreferences(for: occurrence)
        #expect(saved.first { $0.mailAccountID == "b" && $0.threadID == "manual" }?.choice == .include)
    }

    @Test func hiddenAccountSourceMetadataIsNotReadAndProfileSwitchImmediatelyHidesReports() async throws {
        let fixture = try await MeetingModelFixture()
        let occurrence = try MeetingPreparationOccurrence(eventAccountID: "a", calendarID: "calendar", event: fixture.event.event)
        _ = try await fixture.store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: "b", threadID: "hidden", choice: .include)
        let model = fixture.model()
        defer { model.stop() }
        await model.start()
        #expect(fixture.titleReads == [.init(accountID: "a", threadID: "thread")])
        #expect(model.sections.count == 1)
        fixture.ids = ["b"]
        // The computed publication gate must work before its observation task runs.
        #expect(model.sections.isEmpty)
        #expect(model.recentFiles.isEmpty)
        model.revalidateAccess()
        #expect(model.state == .permissionDisabled)
        let manual = ThreadKey(accountID: "b", threadID: "manual")
        await model.include(manual)
        #expect(model.sections.contains { $0.candidate.thread == manual })
        #expect(model.sources.first { $0.key == manual }?.isExplicitlyIncluded == true)
    }

    @Test(.timeLimit(.minutes(1))) func firstPendingSummaryIsRejectedAfterMailSync() async throws {
        let fixture = try await MeetingModelFixture()
        let gate = MeetingModelGate()
        fixture.summaryGate = gate
        let model = fixture.model()
        defer { model.stop() }
        let pending = Task { await model.start() }
        try await gate.untilEntered()
        #expect(model.pendingSummaries.map(\.thread) == [.init(accountID: "a", threadID: "thread")])
        await model.process(.init(accountID: "a", fromHistoryID: 1, toHistoryID: 2,
            messages: [.init(record: fixture.message("new"), labelIDs: [SystemLabel.inbox], addedHistoryID: 2)]))
        gate.release()
        await pending.value
        #expect(model.isStale)
        #expect(model.sections.isEmpty)
        #expect(model.pendingSummaries.isEmpty)
        #expect(!model.isLoading)
    }

    @Test(.timeLimit(.minutes(1))) func missingOrChangedSourceRevisionCannotPublishCapturedReport() async throws {
        for revision in [String?.none, "r2"] {
            let fixture = try await MeetingModelFixture()
            let gate = MeetingModelGate()
            fixture.summaryGate = gate
            let model = fixture.model()
            let pending = Task { await model.start() }
            try await gate.untilEntered()
            fixture.revision = revision
            gate.release()
            await pending.value
            #expect(model.isStale)
            #expect(model.sections.isEmpty)
            model.stop()
        }
    }

    @Test(.timeLimit(.minutes(1))) func exactSavedEventDisappearanceRejectsFirstPendingSummary() async throws {
        let fixture = try await MeetingModelFixture()
        let gate = MeetingModelGate()
        fixture.summaryGate = gate
        let model = fixture.model()
        defer { model.stop() }
        let pending = Task { await model.start() }
        try await gate.untilEntered()
        model.eventUnavailable()
        gate.release()
        await pending.value
        #expect(model.isStale)
        #expect(model.sections.isEmpty)
        #expect(!model.isLoading)
    }

    @Test(.timeLimit(.minutes(1))) func permissionRegrantRejectsLateSummaryAndCancelRemainsRefreshable() async throws {
        let fixture = try await MeetingModelFixture()
        let gate = MeetingModelGate()
        fixture.summaryGate = gate
        let model = fixture.model()
        defer { model.stop() }
        let pending = Task { await model.start() }
        try await gate.untilEntered()
        fixture.permissionRevision += 2
        model.revalidateAccess()
        gate.release()
        await pending.value
        #expect(model.sections.isEmpty)
        #expect(model.state == .permissionDisabled)
        await model.refresh()
        #expect(model.sections.count == 1)
        model.cancel()
        await model.refresh()
        #expect(model.state == .ready)
        #expect(model.sections.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func excludeDuringFirstSummaryRejectsLateResponse() async throws {
        let fixture = try await MeetingModelFixture()
        let gate = MeetingModelGate()
        fixture.summaryGate = gate
        let model = fixture.model()
        defer { model.stop() }
        let pending = Task { await model.start() }
        try await gate.untilEntered()
        await model.exclude(.init(accountID: "a", threadID: "thread"))
        gate.release()
        await pending.value
        #expect(model.sections.isEmpty)
        #expect(model.sources.first?.isExcluded == true)
        #expect(fixture.summaryCount == 1)
    }

    @Test func providerUnavailableKeepsPickerAndMessageOpeningWhileAttachmentOpeningIsExplicit() async throws {
        let fixture = try await MeetingModelFixture()
        let model = fixture.model()
        defer { model.stop() }
        await model.start()
        let file = try #require(model.recentFiles.first)
        model.openSource(file.source)
        #expect(fixture.opened?.messageID == "m1")
        #expect(fixture.opened?.partID == nil)
        fixture.providerUnavailable = true
        await model.refresh()
        #expect(model.state == .providerUnavailable)
        #expect(model.sections.isEmpty)
        model.sourceSearchText = "manual"
        await model.searchSources()
        #expect(model.searchResults.count == 1)
        model.openConversation(try #require(model.searchResults.first?.key))
        #expect(fixture.opened?.threadID == "manual")
    }

    @Test func gridAbsenceIsIgnoredButKnownSavedEventRemovalAndChangesMarkStale() async throws {
        let fixture = try await MeetingModelFixture()
        let model = fixture.model()
        defer { model.stop() }
        await model.start()
        model.eventChanged(nil)
        #expect(!model.isStale)
        var changed = fixture.event.event
        changed.summary = "Changed meeting"
        model.eventChanged(fixture.event.replacingEvent(changed))
        #expect(model.isStale)
        await model.refresh()
        #expect(!model.isStale)
        model.eventUnavailable()
        #expect(model.isStale)
    }
}

@MainActor @Observable private final class MeetingModelFixture {
    let store: AccountStore
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let event = CalendarDisplayEvent(event: .init(id: "event", summary: "Orion review", start: .init(date: "2026-11-05"),
        end: .init(date: "2026-11-06")), accountID: "a", calendarID: "calendar")
    var ids: Set<String> = ["a"]
    var permissionRevision = 1
    var revision: String? = "r1"
    var eventReadFails = false
    var providerUnavailable = false
    var summaryGate: MeetingModelGate?
    var sessionCount = 0
    var summaryCount = 0
    var titleReads: [ThreadKey] = []
    var opened: MailLink?
    var accepted: FollowUpSuggestionRequest?

    init() async throws {
        store = try AccountStore.inMemory()
        for id in ["a", "b"] {
            try await store.save(.init(id: id, email: "\(id)@example.invalid", displayName: id, grantedScopes: [], addedAt: .distantPast))
        }
    }

    func access(_ ids: Set<String>) -> MeetingPreparationAccess {
        .init(scope: .init(accountIDs: ids, threadIDs: nil, accountInstances: Dictionary(uniqueKeysWithValues: ids.map { ($0, "instance") }),
            connectionRevision: 1, canUsePlan: true,
            calendarScope: .init(access: [.init(accountID: "a", calendarID: "calendar"): .details], revision: 1)),
            modelID: "fixture", modelReady: true, permissionRevision: permissionRevision, mailboxRuntime: "fixture")
    }

    func model() -> MeetingPreparationModel {
        MeetingPreparationModel(event: event, followUps: FollowUpsModel(app: nil), store: { self.store }, mailAccountIDs: { self.ids },
            access: { self.access($0) }, makeSession: { _, ids, token in
                self.sessionCount += 1
                let captured = self.access(ids)
                return MeetingPreparationSession(access: captured, providerUnavailableMessage: self.providerUnavailable ? "Connect a provider." : nil,
                    isValid: { token.isCurrent() && self.access(ids) == captured }, discover: { _, included, linked, excluded in
                        var seen: Set<ThreadKey> = []
                        let candidates = (linked + included).compactMap { link -> MeetingPreparationCandidate? in
                            let key = ThreadKey(accountID: link.accountID, threadID: link.threadID)
                            guard ids.contains(key.accountID), !excluded.contains(key), seen.insert(key).inserted else { return nil }
                            return self.candidate(key.accountID, key.threadID)
                        }
                        return .init(candidates: candidates, omittedCount: 0, hasMoreSearchResults: false, requiresManualSelection: false, failures: [])
                    }, summarize: { candidate in
                        self.summaryCount += 1
                        if let gate = self.summaryGate { self.summaryGate = nil; await gate.wait() }
                        return try self.report(candidate)
                    })
            }, readEvent: { event in
                if self.eventReadFails { throw MeetingPreparationServiceError.sourceUnavailable }
                return event
            }, sourceLinks: { _ in [.init(accountID: "a", calendarID: "calendar", eventID: "event", threadID: "thread", messageID: "m1")] },
            sourceTitles: { keys in
                self.titleReads += keys
                return Dictionary(uniqueKeysWithValues: keys.map { ($0, "Orion \($0.threadID)") })
            }, search: { _, ids in
                guard let account = ids.sorted().first else { return [] }
                return [.init(key: .init(accountID: account, threadID: "manual"), link: .init(accountID: account, threadID: "manual"),
                    title: "Manual conversation", reason: "Cached conversation", isExcluded: false, isExplicitlyIncluded: false, unavailableMessage: nil)]
            }, threadRevision: { _ in self.revision }, openMail: { self.opened = $0 }, acceptSuggestion: { self.accepted = $0 })
    }

    func candidate(_ account: String, _ thread: String) -> MeetingPreparationCandidate {
        .init(thread: .init(accountID: account, threadID: thread), title: "Orion \(thread)", reason: .included,
            source: .init(accountID: account, threadID: thread, messageID: "m1"))
    }

    func message(_ id: String, account: String = "a", thread: String = "thread") -> MessageRecord {
        .init(accountID: account, id: id, threadID: thread, historyID: 1, date: date, snippet: "Review Orion", sender: "Jordan",
            recipients: "Alex", cc: nil, subject: "Orion", sizeEstimate: 10)
    }

    func report(_ candidate: MeetingPreparationCandidate) throws -> MeetingPreparationThreadReport {
        let key = candidate.thread
        let messages = ["m1", "m2", "m3"]
        let sources = messages.map { AssistantSource(accountID: key.accountID, threadID: key.threadID, messageID: $0, partID: nil, title: "Orion") }
        let payload: [String: Any] = ["summary": "Review Orion.", "source_ids": [sources[0].id], "decisions": [],
            "open_tasks": sources.map { ["description": "Task \($0.messageID ?? "")", "owner": "Jordan", "source_ids": [$0.id]] as [String: Any] }]
        let summary = try AssistantSummary.decode(JSONSerialization.data(withJSONObject: payload), allowedSourceIDs: Set(sources.map(\.id)))
        let detail = ThreadDetail(thread: .init(accountID: key.accountID, id: key.threadID, lastDate: date, subject: "Orion", snippet: "Review",
            participants: "Jordan", messageCount: messages.count, isUnread: false, isStarred: false), messages: messages.map {
                MessageDetail(record: message($0, account: key.accountID, thread: key.threadID), labels: [SystemLabel.inbox], body: nil, attachments: [])
            })
        let file = MeetingPreparationAttachment(source: .init(accountID: key.accountID, threadID: key.threadID, messageID: "m1", partID: "part", title: "Notes.txt"),
            filename: "Notes.txt", sender: "Jordan", date: date, size: 20, mimeType: "text/plain")
        return .init(candidate: candidate, report: .init(summary: summary, sources: sources, hasPartialCoverage: false,
            messageIDs: Set(messages), totalMessages: messages.count), detail: detail, revision: "r1", attachments: [file])
    }
}

@MainActor private final class MeetingModelGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func untilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(entered)
    }
}
