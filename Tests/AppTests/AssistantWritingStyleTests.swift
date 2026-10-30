import Foundation
import MailStore
import SyncEngine
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct AssistantWritingStyleTests {
    @Test func serialLearningScopesProfilesAndDefersStaleDraftBodies() async throws {
        let reader = StyleReader()
        let analyzer = StyleAnalyzerProbe(pauseFirst: true)
        let store = MemoryAssistantWritingStyleStore()
        let model = makeModel(reader: reader, analyzer: analyzer, store: store, waitLimit: .milliseconds(1))
        model.refresh(accounts: [account("a"), account("b", enabled: false), account("c")],
                      accountListReady: true, connectionRevision: 1, modelID: "test")
        await analyzer.waitForCalls(1)
        #expect(reader.accountIDs == ["a"])
        let earlier = model.round(accountIDs: ["a"], requestID: UUID())
        let clock = ContinuousClock()
        let start = clock.now
        let pending = try await model.draftDecision(accountID: "a", round: earlier)
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(!pending.mayCreateDraft)
        #expect(pending.status == "pending")
        #expect(reader.accountIDs == ["a"])

        await analyzer.release()
        await model.waitForLearning()
        #expect(reader.accountIDs == ["a", "c"])
        #expect(model.entries.first?.sampleCount == 5)
        #expect(model.entries.first?.hasLimitedCoverage == false)
        #expect(try store.load().profiles.count == 2)
        let stale = try await model.draftDecision(accountID: "a", round: earlier)
        #expect(!stale.mayCreateDraft)
        #expect(stale.status == "style_ready")
        let ready = model.round(accountIDs: ["a"], requestID: UUID())
        #expect(Set(ready.hints.keys) == ["a"])
        let context = try ready.promptContext()
        #expect(!context.contains("c@example.invalid"))
        #expect(!context.contains(reader.rawMarker))
        let decision = try await model.draftDecision(accountID: "a", round: ready)
        #expect(decision.mayCreateDraft && decision.styleApplied)
        #expect(model.isDraftDecisionCurrent(accountID: "a", round: ready, decision: decision))
        model.setEnabled("a", enabled: false)
        #expect(!model.isDraftDecisionCurrent(accountID: "a", round: ready, decision: decision))
        let changed = try await model.draftDecision(accountID: "a", round: ready)
        #expect(!changed.mayCreateDraft)
        #expect(changed.status == "style_changed")
    }

    @Test func revocationDeletesAndReenablingLearnsAgainWithoutLosingStartupProfiles() async throws {
        let reader = StyleReader()
        let analyzer = StyleAnalyzerProbe()
        let store = MemoryAssistantWritingStyleStore()
        let model = makeModel(reader: reader, analyzer: analyzer, store: store)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: "test")
        await model.waitForLearning()
        model.refresh(accounts: [account("a", enabled: false)], accountListReady: true, connectionRevision: 1, modelID: "test")
        #expect(try store.load().profiles.isEmpty)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: "test")
        await model.waitForLearning()
        #expect(reader.accountIDs == ["a", "a"])
        model.refresh(accounts: [], accountListReady: false, connectionRevision: 1, modelID: nil)
        #expect(try store.load().profiles.count == 1)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 2, modelID: "test")
        await model.waitForLearning()
        #expect(reader.accountIDs.count == 2)

        model.refresh(accounts: [], accountListReady: false, connectionRevision: 2, modelID: nil)
        model.forgetAccount("a")
        #expect(try store.load().profiles.isEmpty)
        #expect(model.entries.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancelledAnalysisCannotPublishAndReadinessCanRestart(changeIdentity: Bool) async throws {
        let reader = StyleReader()
        let analyzer = StyleAnalyzerProbe(pauseFirst: true)
        let store = MemoryAssistantWritingStyleStore()
        let model = makeModel(reader: reader, analyzer: analyzer, store: store)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: "test")
        await analyzer.waitForCalls(1)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: nil)
        let restored = account("a", instance: changeIdentity ? "replacement" : "a-instance")
        model.refresh(accounts: [restored], accountListReady: true, connectionRevision: 1, modelID: "test")
        await analyzer.release()
        await model.waitForLearning()
        #expect(await analyzer.calls == 2)
        #expect(try store.load().profiles.first?.profile.traits.formality == .informal)
        #expect(model.entries.first?.state == .ready)
    }

    @Test func disablingDuringAnalysisFencesTheLateResult() async throws {
        let reader = StyleReader()
        let analyzer = StyleAnalyzerProbe(pauseFirst: true)
        let store = MemoryAssistantWritingStyleStore()
        let model = makeModel(reader: reader, analyzer: analyzer, store: store)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: "test")
        await analyzer.waitForCalls(1)
        model.setEnabled("a", enabled: false)
        await analyzer.release()
        await model.waitForLearning()
        #expect(try store.load().profiles.isEmpty)
        #expect(!model.isEnabled("a"))
        model.setEnabled("a", enabled: true)
        await model.waitForLearning()
        #expect(await analyzer.calls == 2)
        #expect(try store.load().profiles.count == 1)
    }

    @Test func failedOrInsufficientRelearnKeepsOldProfileButShowsTheOutcome() async throws {
        let reader = StyleReader()
        let analyzer = StyleAnalyzerProbe()
        let store = MemoryAssistantWritingStyleStore()
        let model = makeModel(reader: reader, analyzer: analyzer, store: store)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: "test")
        await model.waitForLearning()
        let original = try #require(store.load().profiles.first)
        await analyzer.setOutcome(.failure)
        model.relearn("a")
        await model.waitForLearning()
        #expect(model.entries.first?.state == .failed)
        #expect(try store.load().profiles.first == original)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: "test")
        await model.waitForLearning()
        #expect(await analyzer.calls == 2)
        await analyzer.setOutcome(.insufficient)
        model.relearn("a")
        await model.waitForLearning()
        #expect(model.entries.first?.state == .insufficient)
        #expect(model.entries.first?.statusText.contains("previous profile") == true)
        #expect(try store.load().profiles.first == original)
        let decision = try await model.draftDecision(accountID: "a", round: model.round(accountIDs: ["a"], requestID: UUID()))
        #expect(decision.mayCreateDraft && decision.styleApplied)
    }

    @Test func storageContainsProfilesOnlyAndCorruptLoadOptOutDoesNotRewriteIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TernStyleTests-" + UUID().uuidString)
        let domain = "TernStyleTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: directory); preferences.removePersistentDomain(forName: domain) }
        let file = directory.appending(path: "styles.json")
        let store = FileAssistantWritingStyleStore(url: file, preferences: preferences)
        let reader = StyleReader()
        let analyzer = StyleAnalyzerProbe()
        let model = makeModel(reader: reader, analyzer: analyzer, store: store)
        model.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 1, modelID: "test")
        await model.waitForLearning()
        let saved = try Data(contentsOf: file)
        #expect(saved.range(of: Data(reader.rawMarker.utf8)) == nil)
        #expect(saved.range(of: Data("synthetic-message-".utf8)) == nil)
        #expect(try store.load().profiles.count == 1)

        let corrupt = Data("invalid profile archive".utf8)
        try corrupt.write(to: file)
        let restored = makeModel(reader: reader, analyzer: analyzer, store: store)
        restored.refresh(accounts: [account("a", enabled: false)], accountListReady: true, connectionRevision: 1, modelID: "test")
        restored.setEnabled("a", enabled: false)
        #expect(try Data(contentsOf: file) == corrupt)
        #expect(store.disabledAccountIDs.contains("a"))
        #expect(restored.storageErrorMessage != nil)
        let restarted = makeModel(reader: reader, analyzer: analyzer, store: store)
        restarted.refresh(accounts: [account("a")], accountListReady: true, connectionRevision: 2, modelID: "test")
        await restarted.waitForLearning()
        #expect(!restarted.isEnabled("a"))
        #expect(reader.accountIDs.count == 1)
    }

    @Test func disabledMarkerSurvivesAnUnwritableProfileLocation() throws {
        let domain = "TernStyleMarkerTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let store = FileAssistantWritingStyleStore(url: nil, preferences: preferences)
        var archive = AssistantWritingStyleArchive()
        archive.disabledAccountIDs = ["a"]
        #expect(throws: AssistantWritingStyleStoreError.unavailable) { try store.save(archive) }
        #expect(store.disabledAccountIDs == ["a"])
    }

    @Test func draftToolRequiresCurrentRoundStyleAndRechecksBeforeQueueing() async throws {
        let mailbox = MailboxModel(
            account: AccountRecord(id: "first", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now),
            cache: try MailCache.inMemory(), gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "StyleDraftTests-" + UUID().uuidString))
        let owner = try #require(mailbox.account(id: "first"))
        let profile = try WritingStyleProfile(sampleCount: 5, profiledAt: .now,
            traits: .init(formality: .formal, directness: .direct, detail: .brief))
        let store = MemoryAssistantWritingStyleStore(archive: .init(profiles: [
            .init(accountID: "first", email: "audit@example.invalid", revision: UUID(), profile: profile, hasLimitedCoverage: false)
        ]))
        let model = makeModel(reader: StyleReader(), analyzer: StyleAnalyzerProbe(), store: store)
        model.refresh(accounts: [.init(id: "first", email: "audit@example.invalid", displayName: nil,
            instanceID: String(describing: ObjectIdentifier(owner)), isMailAccessEnabled: true)],
            accountListReady: true, connectionRevision: 1, modelID: "test")
        let tools = MailAssistantTools(mailbox: mailbox, allowedAccountIDs: ["first"]) { true }
        tools.writingStyleGate = { try await model.draftDecision(accountID: $0, round: $1) }
        var commitChecks = 0
        var disableBeforeCommit = false
        tools.writingStyleIsCurrent = { accountID, round, decision in
            commitChecks += 1
            if disableBeforeCommit, commitChecks == 2 { model.setEnabled(accountID, enabled: false) }
            return model.isDraftDecisionCurrent(accountID: accountID, round: round, decision: decision)
        }
        func request(_ id: String, body: String) throws -> AIToolCall {
            .init(id: id, namespace: "tern", name: "prepare_draft", arguments: try AIJSON.object([
                "account_id": .string("first"), "thread_id": .null, "message_id": .null,
                "to": .array([.string("recipient@example.invalid")]), "subject": .string("Proposal"),
                "body": .string(body), "reply_mode": .string("new")
            ]).jsonString())
        }
        let stale = try await tools.execute(request("first-draft", body: "Earlier body."),
            writingStyleRound: .init(requestID: UUID(), hints: [:]))
        #expect(stale.createdDraftID == nil)
        #expect(stale.data["style_status"]?.stringValue == "style_ready")
        #expect(try await mailbox.cache.read { try $0.localDrafts(accountID: "first") }.isEmpty)

        let readyRound = model.round(accountIDs: ["first"], requestID: UUID())
        let revised = try request("first-draft", body: "Revised using the current writing profile.")
        let created = try await tools.execute(revised, writingStyleRound: readyRound)
        let draftID = try #require(created.createdDraftID)
        #expect(created.data["style_applied"]?.boolValue == true)
        #expect(created.draftStyleNote == nil)
        tools.acknowledge(callID: revised.id)

        // The engine invokes this fence again after its asynchronous cache/source
        // reads. Changing policy at that boundary must prevent the queued write.
        commitChecks = 0
        disableBeforeCommit = true
        await #expect(throws: AssistantMailError.accessChanged) {
            try await tools.execute(request("changed-draft", body: "Stale personalized body."), writingStyleRound: readyRound)
        }
        #expect(commitChecks == 2)
        #expect(try await mailbox.cache.read { try $0.localDrafts(accountID: "first") }.count == 1)
        disableBeforeCommit = false
        let staleAfterOff = try await tools.execute(request("stale-after-off", body: "Earlier personalized text."), writingStyleRound: readyRound)
        #expect(staleAfterOff.createdDraftID == nil)
        #expect(staleAfterOff.data["style_status"]?.stringValue == "style_changed")
        #expect(try await mailbox.cache.read { try $0.localDrafts(accountID: "first") }.count == 1)
        let replay = try await tools.execute(revised, writingStyleRound: readyRound)
        #expect(replay.createdDraftID == draftID)
        let fallback = try await tools.execute(request("generic-draft", body: "Use only the current request."),
            writingStyleRound: model.round(accountIDs: ["first"], requestID: UUID()))
        #expect(fallback.createdDraftID != nil)
        #expect(fallback.data["style_applied"]?.boolValue == false)
        #expect(fallback.data["style_status"]?.stringValue == "off")
        #expect(fallback.draftStyleNote?.isEmpty == false)
        await mailbox.stop()
    }

    private func makeModel(reader: StyleReader, analyzer: StyleAnalyzerProbe,
                           store: any AssistantWritingStyleStore, waitLimit: Duration = .seconds(10)) -> AssistantWritingStyleModel {
        AssistantWritingStyleModel(store: store, readSamples: { account, authorized in
            guard await authorized() else { throw CancellationError() }
            return reader.read(account.id)
        }, analyze: { samples, model, date in
            try await analyzer.analyze(samples, model: model, date: date)
        }, draftWaitLimit: waitLimit)
    }

    private func account(_ id: String, enabled: Bool = true, instance: String? = nil) -> AssistantWritingStyleAccount {
        .init(id: id, email: "\(id)@example.invalid", displayName: nil,
              instanceID: instance ?? "\(id)-instance", isMailAccessEnabled: enabled)
    }
}

@MainActor private final class StyleReader {
    private(set) var accountIDs: [String] = []
    let rawMarker = "RAW_SENT_BODY_TEST_MARKER"
    func read(_ accountID: String) -> AssistantWritingSamples {
        accountIDs.append(accountID)
        let samples = (0..<5).map {
            AssistantWritingSample(messageID: "synthetic-message-\($0)", date: .distantPast,
                text: rawMarker + String(repeating: " Please review the proposed date and let me know what works.", count: 4), truncated: false)
        }
        return .init(accountID: accountID, requestedCount: 100, selectedCount: 5, inspectedCount: 5,
                     samples: samples, skippedCount: 0, failures: [], truncated: false, hasMoreSentMail: false)
    }
}

private actor StyleAnalyzerProbe {
    enum Outcome { case profile, insufficient, failure }
    private(set) var calls = 0
    private let pauseFirst: Bool
    private var outcome = Outcome.profile
    private var pause: CheckedContinuation<Void, Never>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(pauseFirst: Bool = false) { self.pauseFirst = pauseFirst }
    func setOutcome(_ outcome: Outcome) { self.outcome = outcome }
    func analyze(_ samples: [String], model: String, date: Date) async throws -> WritingStyleProfile? {
        calls += 1
        let call = calls
        let ready = waiters.filter { calls >= $0.0 }
        waiters.removeAll { calls >= $0.0 }
        ready.forEach { $0.1.resume() }
        if pauseFirst, call == 1 { await withCheckedContinuation { pause = $0 } }
        switch outcome {
        case .failure: throw WritingStyleError.invalidResponse
        case .insufficient: return nil
        case .profile:
            return try .init(sampleCount: samples.count, profiledAt: date,
                traits: .init(formality: call == 1 ? .formal : .informal, directness: .direct, detail: .brief))
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release() { pause?.resume(); pause = nil }
}
