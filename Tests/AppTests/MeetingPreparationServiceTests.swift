import Foundation
import GmailAPI
import MessageContent
import Testing
import TernAI
@testable import MailStore
@testable import Tern

@Suite @MainActor struct MeetingPreparationServiceTests {
    @Test func factoryIsIndependentOfChatAndInvalidatesRegrantRuntimeAndCalendarPermission() async throws {
        let fixture = try MeetingServiceFactoryFixture()
        defer { fixture.clean() }
        await fixture.assistant.refreshConnection()
        fixture.assistant.selectedScope = .selectedThreads
        fixture.context.selected = [.init(accountID: "b", threadID: "unrelated")]
        let event = Self.event("Meeting")
        let service = try fixture.assistant.makeMeetingPreparationService(event: event, accountIDs: ["a"], isCurrent: { true })
        #expect(service.access.scope.accountIDs == ["a"])
        #expect(service.access.scope.threadIDs == nil)
        fixture.assistant.selectedScope = .currentAccount
        fixture.context.current = ["b"]
        #expect(service.isValid())
        #expect(fixture.assistant.messages.isEmpty)
        fixture.assistant.setAccountEnabled("a", enabled: false)
        fixture.assistant.setAccountEnabled("a", enabled: true)
        #expect(!service.isValid())
        let replacement = try fixture.assistant.makeMeetingPreparationService(event: event, accountIDs: ["a"], isCurrent: { true })
        fixture.context.instances["a"] = "re-added-account"
        #expect(!replacement.isValid())
        fixture.context.calendar.access[.init(accountID: "a", calendarID: "calendar")] = .availability
        #expect(throws: MeetingPreparationServiceError.calendarDetailsRequired) {
            try fixture.assistant.makeMeetingPreparationService(event: event, accountIDs: ["a"], isCurrent: { true })
        }
        #expect(await fixture.provider.requestCount == 0)
    }

    @Test func explicitSourcesWinExclusionsAndCandidatesStayBoundedWithoutProvider() async throws {
        let event = Self.event("Catch-up")
        let provider = MeetingServiceProvider()
        var searches = 0
        let service = Self.service(event: event, provider: provider, canUsePlan: false, execute: { _ in
            searches += 1; return .init(data: .null)
        })
        let included = (0..<24).map { MailLink(accountID: "a", threadID: "thread-\($0)") }
        let excluded: Set<ThreadKey> = [.init(accountID: "a", threadID: "thread-0")]
        let result = try await service.discover(event: event, included: included,
            linked: [included[1], .init(accountID: "b", threadID: "thread-1")], excluded: excluded)
        #expect(result.candidates.count == 20)
        #expect(result.omittedCount == 4)
        #expect(result.candidates.first?.source == included[1])
        #expect(result.candidates.allSatisfy { $0.reason == .included })
        #expect(result.requiresManualSelection)
        #expect(searches == 0)
        #expect(service.providerUnavailableMessage != nil)
        #expect(await provider.requestCount == 0)
    }

    @Test func discoveryRequiresContentEvidenceAndNeverUsesAnAttendeeAsTheTitleEvidence() async throws {
        var person = GoogleCalendarEvent(id: "event", summary: "Meeting with Alexandra")
        person.attendees = [.init(email: "alexandra@example.invalid", displayName: "Alexandra")]
        let personEvent = CalendarDisplayEvent(event: person, accountID: "a", calendarID: "calendar")
        #expect(MeetingPreparationMatching.terms(in: personEvent).isEmpty)
        let event = Self.event("Orion migration review")
        let provider = MeetingServiceProvider()
        var calls = 0
        let matching = Self.source("a", "relevant", message: nil)
        let unrelated = Self.source("a", "person-only", message: nil)
        let service = Self.service(event: event, provider: provider, execute: { call in
            calls += 1
            #expect(call.name == "search_mail")
            return .init(data: .object(["pages": .array([.object(["account_id": .string("a"), "has_more": .bool(true),
                "threads": .array([Self.searchRow(matching, subject: "Orion migration options", snippet: "Plan"),
                    Self.searchRow(unrelated, subject: "Lunch", snippet: "Alexandra will attend")])])])]), sources: [matching, unrelated])
        })
        let found = try await service.discover(event: event, included: [], linked: [], excluded: [])
        #expect(found.candidates.map(\.thread.threadID) == ["relevant"])
        #expect(found.hasMoreSearchResults)
        #expect(calls <= MeetingPreparationService.searchLimit)
        #expect(await provider.requestCount == 0)
    }

    @Test func reportUsesOneFullReadFreshAttachmentsAndFiveReportBudget() async throws {
        let event = Self.event("Meeting")
        let provider = MeetingServiceProvider()
        let detail = Self.detail()
        let read = Self.read()
        var fullReads = 0
        let service = Self.service(event: event, provider: provider, execute: { call in
            #expect(call.name == "read_thread")
            fullReads += 1
            return read
        }, detail: { _ in detail })
        let discovery = try await service.discover(event: event, included: [.init(accountID: "a", threadID: "thread")], linked: [], excluded: [])
        let candidate = try #require(discovery.candidates.first)
        for _ in 0..<5 {
            let result = try await service.summarize(candidate)
            #expect(result.report.sources.map(\.messageID) == ["m1"])
            #expect(result.attachments.map(\.filename) == ["New.pdf", "Old.pdf"])
            #expect(result.attachments.first?.source.messageID == "m2")
            #expect(result.attachments.first?.source.partID == "part-new")
            #expect(result.detail.messages.flatMap(\.attachments).allSatisfy { $0.filename != "Stale.pdf" })
        }
        await #expect(throws: MeetingPreparationServiceError.reportLimit) { try await service.summarize(candidate) }
        #expect(fullReads == 5)
        #expect(await provider.requestCount == 5)
    }

    @Test func invalidOwnershipOrMembershipFailsBeforeProviderAndCitationsAreChecked() async throws {
        let detail = Self.detail()
        let read = Self.read()
        let key = ThreadKey(accountID: "a", threadID: "thread")
        let foreign = AssistantToolResult(data: read.data,
            sources: [Self.source("b", "thread", message: "m1"), Self.source("a", "thread", message: "m2")])
        #expect(throws: MeetingPreparationServiceError.invalidSource) {
            try MeetingPreparationEvidence.detail(detail, read: foreign, thread: key)
        }
        var missing = detail; missing.messages.removeLast()
        #expect(throws: MeetingPreparationServiceError.invalidSource) {
            try MeetingPreparationEvidence.detail(missing, read: read, thread: key)
        }
        let summary = try AssistantSummary.decode(Data(Self.summary(sourceID: "foreign").utf8), allowedSourceIDs: ["foreign"])
        let report = ThreadSummaryReport(summary: summary, sources: [Self.source("a", "thread", message: "m1")],
            hasPartialCoverage: false, messageIDs: ["m1", "m2"], totalMessages: 2)
        #expect(throws: MeetingPreparationServiceError.invalidSource) {
            try MeetingPreparationService.validate(report: report, detail: detail, thread: key)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aSuspendedProviderCannotPublishAfterConsentInvalidation() async throws {
        let event = Self.event("Meeting")
        let provider = MeetingServiceProvider(suspended: true)
        let access = MeetingServiceValidity()
        let service = Self.service(event: event, provider: provider, execute: { _ in Self.read() },
            detail: { _ in Self.detail() }, valid: { access.valid })
        let discovery = try await service.discover(event: event, included: [.init(accountID: "a", threadID: "thread")], linked: [], excluded: [])
        let candidate = try #require(discovery.candidates.first)
        let pending = Task { try await service.summarize(candidate) }
        await provider.waitUntilRequested()
        access.valid = false
        await provider.release()
        do {
            _ = try await pending.value
            Issue.record("A revoked preparation returned a report.")
        } catch AssistantError.accessChanged {
            // A suspended provider must not publish after its captured access changed.
        } catch {
            Issue.record("Expected an access change, received \(error).")
        }
        #expect(await provider.requestCount == 1)
    }

    private static func service(event: CalendarDisplayEvent, provider: MeetingServiceProvider, canUsePlan: Bool = true,
                                execute: @escaping @MainActor (AIToolCall) async throws -> AssistantToolResult,
                                detail: @escaping @MainActor (ThreadKey) async throws -> ThreadDetail? = { _ in nil },
                                valid: @escaping @MainActor () -> Bool = { true }) -> MeetingPreparationService {
        let scope = AssistantScopeSnapshot(accountIDs: ["a", "b"], threadIDs: nil,
            accountInstances: ["a": "one", "b": "two"], connectionRevision: 1, canUsePlan: canUsePlan,
            calendarScope: .init(access: [.init(accountID: "a", calendarID: "calendar"): .details], revision: 1))
        let access = MeetingPreparationAccess(scope: scope, modelID: "test", modelReady: true, permissionRevision: 1, mailboxRuntime: "runtime")
        return MeetingPreparationService(event: event, access: access,
            tools: .init(definitions: MailAssistantTools.definitions, execute: execute), provider: provider, loadDetail: detail, isValid: valid)
    }

    private static func event(_ title: String) -> CalendarDisplayEvent {
        CalendarDisplayEvent(event: GoogleCalendarEvent(id: "event", summary: title), accountID: "a", calendarID: "calendar")
    }
    private static func source(_ account: String, _ thread: String, message: String?) -> AssistantSource {
        AssistantSource(accountID: account, threadID: thread, messageID: message, partID: nil, title: "Orion migration")
    }
    private static func searchRow(_ source: AssistantSource, subject: String, snippet: String) -> AIJSON {
        .object(["account_id": .string(source.accountID), "thread_id": .string(source.threadID), "source_id": .string(source.id),
            "subject": .string(subject), "snippet": .string(snippet)])
    }
    private static func detail() -> ThreadDetail {
        let messages = ["m1", "m2"].enumerated().map { index, id in
            let record = MessageRecord(accountID: "a", id: id, threadID: "thread", historyID: 1,
                date: Date(timeIntervalSince1970: Double(index + 1)), snippet: "Please review.", sender: "Sender",
                recipients: "Me", cc: nil, subject: "Orion migration", sizeEstimate: 10)
            return MessageDetail(record: record, labels: [SystemLabel.inbox], body: nil,
                attachments: [.init(accountID: "a", messageID: id, partID: "stale", attachmentID: nil,
                    filename: "Stale.pdf", mimeType: "application/pdf", size: 10, isInline: false)])
        }
        return ThreadDetail(thread: ThreadRecord(accountID: "a", id: "thread", lastDate: Date(timeIntervalSince1970: 2),
            subject: "Orion migration", snippet: "Please review.", participants: "Sender", messageCount: 2,
            isUnread: false, isStarred: false), messages: messages)
    }
    private static func read() -> AssistantToolResult {
        let sources = [source("a", "thread", message: "m1"), source("a", "thread", message: "m2")]
        let messages: [AIJSON] = ["m1", "m2"].enumerated().map { index, id in
            .object(["message_id": .string(id), "thread_id": .string("thread"), "text": .string("Please review the proposal."),
                "attachments": .array([.object(["account_id": .string("a"), "message_id": .string(id),
                    "part_id": .string(index == 0 ? "part-old" : "part-new"), "filename": .string(index == 0 ? "Old.pdf" : "New.pdf"),
                    "mime_type": .string("application/pdf"), "size": .number(10), "is_inline": .bool(false)])])])
        }
        return AssistantToolResult(data: .object(["account_id": .string("a"), "thread_id": .string("thread"),
            "messages": .array(messages), "total_messages": .number(2), "truncated": .bool(false)]), sources: sources)
    }
    fileprivate static func summary(sourceID: String = "tern:a/thread/m1/") -> String {
        "{\"summary\":\"The proposal needs review.\",\"source_ids\":[\"\(sourceID)\"],\"decisions\":[],\"open_tasks\":[]}"
    }
}

@MainActor private final class MeetingServiceValidity { var valid = true }

@MainActor private final class MeetingServiceFactoryContext {
    let accounts = ["a", "b"].map { AccountRecord(id: $0, email: "\($0)@example.invalid", displayName: nil, grantedScopes: [], addedAt: .distantPast) }
    var current: Set<String> = ["a"]
    var selected: Set<ThreadKey> = []
    var instances = ["a": "one", "b": "two"]
    var calendar = AssistantCalendarScope(access: [.init(accountID: "a", calendarID: "calendar"): .details], revision: 1)
    func value() -> AssistantContext {
        .init(accounts: accounts, isAccountListReady: true, currentAccountIDs: current, selectedThreads: selected,
            accountInstances: instances, connectionRevision: 1, canUsePlan: true, calendarScope: calendar)
    }
}

@MainActor private struct MeetingServiceFactoryFixture {
    let domain = "MeetingServiceTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let context = MeetingServiceFactoryContext()
    let provider = MeetingServiceProvider()
    let assistant: AssistantModel
    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        let context = context
        assistant = AssistantModel(app: AppModel(), connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
            provider: provider, defaults: defaults, context: { context.value() }, makeTools: { _ in
                .init(definitions: MailAssistantTools.definitions, execute: { _ in .init(data: .object(["pages": .array([])])) })
            })
        assistant.setAccountEnabled("a", enabled: true)
    }
    func clean() { assistant.stop(); defaults.removePersistentDomain(forName: domain) }
}

private actor MeetingServiceProvider: AIProvider {
    private let suspended: Bool
    private var continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0
    init(suspended: Bool = false) { self.suspended = suspended }
    func models() async throws -> [AIModel] { [.init(id: "test", displayName: "Test")] }
    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in Task { await self.respond(continuation) } }
    }
    private func respond(_ continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        requestCount += 1
        self.continuation = continuation
        for waiter in waiters { waiter.resume() }; waiters = []
        if !suspended { release() }
    }
    func waitUntilRequested() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        continuation?.yield(.completed(AIResponse(output: [], text: "{\"summary\":\"The proposal needs review.\",\"source_ids\":[\"tern:a/thread/m1/\"],\"decisions\":[],\"open_tasks\":[]}", toolCalls: [])))
        continuation?.finish(); continuation = nil
    }
}
