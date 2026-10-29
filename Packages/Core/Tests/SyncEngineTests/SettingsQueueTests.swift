import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct SettingsQueueTests {
    let news = GmailFilter(criteria: .init(from: "news@example.com"), action: .init(removeLabelIds: [SystemLabel.inbox]))
    let mine = GmailFilter(id: "mine", criteria: .init(from: "boss@example.com"), action: .init(addLabelIds: [SystemLabel.starred]))

    @Test func anEditCreatesBeforeItDeletesAndNeverCreatesTwice() async throws {
        let (engine, cache, settings, clock) = try await makeSettingsEngine(filters: [mine])
        let edited = GmailFilter(criteria: mine.criteria, action: .init(addLabelIds: [SystemLabel.important]))
        let edit = try #require(try await engine.replaceFilter(mine, with: edited))
        clock.advance(3)

        // Gmail creates the new filter, but its answer is lost.
        await settings.loseAnswer("create")
        #expect(await engine.sendDueSettings() == 1)
        // The retry finds it, records its ID, then the delete fails.
        await settings.fail("delete mine", with: .transport(.timedOut))
        clock.advance(2)
        #expect(await engine.sendDueSettings() == 1)
        let row = try #require(try await rows(cache).first)
        #expect(row.settingsChange == .replaceFilter(oldID: "mine", old: mine, new: edited, listedIDs: ["mine"], newID: "f1"))
        clock.advance(4)
        #expect(await engine.sendDueSettings() == 1)
        #expect(await settings.calls == ["list", "create", "list", "delete mine", "list", "delete mine"])
        #expect(await settings.rules == [edited])

        try await engine.undo(edit)
        while await engine.sendDueSettings() > 0 {}
        #expect(await settings.rules == [GmailFilter(criteria: mine.criteria, action: mine.action)])
        #expect(try await rows(cache).allSatisfy { $0.state == .sent })
    }

    @Test func aRefusedRetryLooksForItsFilterBeforeFailing() async throws {
        let (engine, _, settings, clock) = try await makeSettingsEngine(filters: [mine])
        // Gmail stores forwarding addresses in lowercase.
        let forward = GmailFilter(criteria: .init(subject: "Invoice"), action: .init(forward: "Billing@Example.com"))
        let create = try await engine.createFilter(forward)
        await settings.loseAnswer("create")
        clock.advance(3)
        #expect(await engine.sendDueSettings() == 1)

        // A list that lags behind the create misses it, and Gmail refuses a second copy.
        await settings.hideFromNextList("f1")
        clock.advance(2)
        #expect(await engine.sendDueSettings() == 1)
        #expect(await settings.calls == ["list", "create", "list", "create", "list"])
        #expect(await settings.filterIDs == ["mine", "f1"])

        try await engine.undo(create)
        while await engine.sendDueSettings() > 0 {}
        #expect(await settings.filterIDs == ["mine"])
    }

    @Test func anUndoBeforeGmailAnswersWaitsAndStillDeletesTheFilter() async throws {
        let (engine, _, settings, clock) = try await makeSettingsEngine(filters: [mine])
        let create = try await engine.createFilter(news)
        await settings.duringNextCreate {
            try? await engine.undo(create)
            // The reverse waits until the create has finished.
            #expect(await engine.sendDueSettings() == 0)
        }
        clock.advance(3)
        #expect(await engine.sendDueSettings() == 1)
        #expect(await settings.filterIDs == ["mine", "f1"])

        #expect(await engine.sendDueSettings() == 1)
        #expect(await settings.filterIDs == ["mine"])
        #expect(await settings.calls == ["list", "create", "list", "delete f1"])
    }

    @Test func vacationEditsKeepGmailsNewerFieldsAndGoOutInOrder() async throws {
        let shown = VacationSettings(responseSubject: "Away", responseBodyPlainText: "Out")
        let (engine, _, settings, clock) = try await makeSettingsEngine(vacation: shown)
        var enabled = shown
        enabled.enableAutoReply = true
        _ = try await engine.updateVacation(enabled, from: shown)
        var renamed = enabled
        renamed.responseSubject = "Away this week"
        _ = try await engine.updateVacation(renamed, from: enabled)
        // Someone changes the message in Gmail after the pane opened.
        await settings.setVacation(VacationSettings(responseSubject: "Away", responseBodyPlainText: "Out until Monday"))

        await settings.fail("updateVacation", with: .server(status: 503))
        clock.advance(3)
        #expect(await engine.sendDueSettings() == 1)
        // The second edit waits for the first, even during its backoff.
        #expect(await engine.sendDueSettings() == 0)
        clock.advance(2)
        while await engine.sendDueSettings() > 0 {}

        #expect(await settings.calls == ["vacation", "updateVacation", "vacation", "updateVacation", "vacation", "updateVacation"])
        #expect(await settings.vacationSettings == VacationSettings(
            enableAutoReply: true, responseSubject: "Away this week", responseBodyPlainText: "Out until Monday"
        ))
    }

    @Test func aMissingScopeFailsTheRowWithoutRetrying() async throws {
        let (engine, cache, settings, clock) = try await makeSettingsEngine()
        let create = try await engine.createFilter(news)
        await settings.fail("create", with: .http(status: 403, reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT"))
        clock.advance(3)
        #expect(await engine.sendDueSettings() == 1)
        #expect(try await rows(cache).isEmpty)

        try await engine.undo(create)
        clock.advance(300)
        #expect(await engine.sendDueSettings() == 0)
        #expect(await settings.calls == ["list", "create"])
        #expect(await events(engine) == [.actionFailed(
            "Gmail didn't save the change because Tern can't edit this account's settings. Turn on Gmail Settings for the account, then make the change again."
        )])
    }
}

/// Gmail's settings for one account. IDs go "f1", "f2" and so on.
actor FakeSettings: SettingsService {
    private(set) var calls: [String] = []
    private(set) var vacationSettings: VacationSettings
    private var filterList: [GmailFilter]
    private var nextID = 1
    private var errors: [String: [GmailError]] = [:]
    private var lostAnswers: Set<String> = []
    private var hidden: Set<String> = []
    private var createHook: (@Sendable () async -> Void)?

    init(filters: [GmailFilter], vacation: VacationSettings) {
        filterList = filters
        vacationSettings = vacation
    }

    var filterIDs: [String] { filterList.compactMap(\.id) }
    /// The filters without their IDs, to compare content.
    var rules: [GmailFilter] { filterList.map { GmailFilter(criteria: $0.criteria, action: $0.action) } }

    /// The next `call` throws `error` before reaching Gmail.
    func fail(_ call: String, with error: GmailError) { errors[call, default: []].append(error) }
    /// The next `call` reaches Gmail, but its answer is lost.
    func loseAnswer(_ call: String) { lostAnswers.insert(call) }
    func hideFromNextList(_ id: String) { hidden.insert(id) }
    func setVacation(_ settings: VacationSettings) { vacationSettings = settings }
    /// Runs inside the next create, once Gmail has the filter.
    func duringNextCreate(_ hook: @escaping @Sendable () async -> Void) { createHook = hook }

    func filters() throws -> [GmailFilter] {
        try begin("list")
        defer { hidden = [] }
        return filterList.filter { !hidden.contains($0.id ?? "") }
    }

    func createFilter(criteria: GmailFilter.Criteria, action: GmailFilter.Action) async throws -> GmailFilter {
        try begin("create")
        var action = action
        action.forward = action.forward?.lowercased()
        let filter = GmailFilter(id: "f\(nextID)", criteria: criteria, action: action)
        if filterList.contains(where: { $0.hasSameRules(as: filter) }) {
            throw GmailError.http(status: 400, reason: "failedPrecondition")
        }
        nextID += 1
        filterList.append(filter)
        if let hook = createHook {
            createHook = nil
            await hook()
        }
        try end("create")
        return filter
    }

    func deleteFilter(id: String) throws {
        try begin("delete \(id)")
        filterList.removeAll { $0.id == id }
    }

    func vacation() throws -> VacationSettings {
        try begin("vacation")
        return vacationSettings
    }

    func updateVacation(_ settings: VacationSettings) throws -> VacationSettings {
        try begin("updateVacation")
        vacationSettings = settings
        return settings
    }

    func updateSignature(sendAsEmail: String, signature: String) throws -> SendAsIdentity {
        try begin("signature \(sendAsEmail)")
        let body = try JSONSerialization.data(withJSONObject: ["sendAsEmail": sendAsEmail, "signature": signature])
        return try JSONDecoder().decode(SendAsIdentity.self, from: body)
    }

    private func begin(_ call: String) throws {
        calls.append(call)
        if let error = errors[call]?.first {
            errors[call]?.removeFirst()
            throw error
        }
    }

    private func end(_ call: String) throws {
        if lostAnswers.remove(call) != nil { throw GmailError.transport(.timedOut) }
    }
}

func makeSettingsEngine(
    filters: [GmailFilter] = [], vacation: VacationSettings = VacationSettings()
) async throws -> (SyncEngine, MailCache, FakeSettings, TestClock) {
    let cache = try MailCache.inMemory()
    let settings = FakeSettings(filters: filters, vacation: vacation)
    let clock = TestClock()
    let engine = SyncEngine(
        accountID: account,
        sender: EmailAddress(name: "Me", address: "me@example.com"),
        outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernTests-\(UUID().uuidString)", directoryHint: .isDirectory),
        gmail: FakeGmail(),
        settings: settings,
        cache: cache,
        sendsAutomatically: false,
        now: clock.now
    )
    return (engine, cache, settings, clock)
}

private func rows(_ cache: MailCache) async throws -> [PendingAction] {
    try await cache.read { tx in try tx.pendingActions(accountID: account) }
}

private func events(_ engine: SyncEngine) async -> [SyncEvent] {
    await engine.stop()
    var events: [SyncEvent] = []
    for await event in engine.events { events.append(event) }
    return events
}
