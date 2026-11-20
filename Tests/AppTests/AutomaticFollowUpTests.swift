import Foundation
import MailStore
import SyncEngine
import TernAI
import Testing
@testable import Tern

@Suite @MainActor struct AutomaticFollowUpTests {
    @Test func inMemoryPreferencesDoNotPersistBetweenInstances() {
        let first = Date(timeIntervalSince1970: 1_900_000_000)
        let preferences = FollowUpPreferences(defaults: nil, now: { first })
        preferences.delayDays = 12
        preferences.automaticRemindersEnabled = false
        preferences.automaticDraftsEnabled = true
        let fresh = FollowUpPreferences(defaults: nil, now: { first + 60 })
        #expect(fresh.delayDays == 3)
        #expect(fresh.automaticRemindersEnabled)
        #expect(!fresh.automaticDraftsEnabled)
        #expect(fresh.enabledSince == first + 60)
    }

    @Test func preferencesPersistDelayAndKeepDraftsOptInWithANewEnableBoundary() {
        let suite = "automatic-follow-up-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Date(timeIntervalSince1970: 1_900_000_000)
        var clock = first
        let settings = FollowUpPreferences(defaults: defaults, now: { clock })
        #expect(settings.automaticRemindersEnabled)
        #expect(settings.delayDays == 3)
        #expect(!settings.automaticDraftsEnabled)
        settings.delayDays = 1_000
        #expect(settings.delayDays == 365)
        settings.automaticDraftsEnabled = true
        settings.automaticRemindersEnabled = false
        clock += 60
        settings.automaticRemindersEnabled = true
        let restored = FollowUpPreferences(defaults: defaults)
        #expect(restored.delayDays == 365)
        #expect(restored.automaticDraftsEnabled)
        #expect(restored.enabledSince == clock)
    }

    @Test func candidateUsesLatestVerifiedSentAndAnyExternalRecipientReply() async throws {
        let fixture = try await AutomaticFixture()
        var snapshot = fixture.snapshot
        snapshot.messages[0].sender = "Alias <alias@example.com>"
        snapshot.messages[0].recipients = "me@example.com"
        snapshot.messages[0].cc = "Anna <anna@example.com>, Bob <bob@example.com>"
        #expect(AutomaticFollowUpCoordinator.candidate(in: snapshot)?.ownerEmail == nil)
        // Unsubscribe and no-reply mailboxes never answer, so only the people are waited on.
        snapshot.messages[0].cc = "Anna <anna@example.com>, news+unsubscribe@lists.example.com"
        #expect(AutomaticFollowUpCoordinator.candidate(in: snapshot)?.ownerEmail == "anna@example.com")
        snapshot.messages[0].cc = "news+unsubscribe@lists.example.com, No Reply <no-reply@example.com>"
        #expect(AutomaticFollowUpCoordinator.evaluate(snapshot) == .automatedRecipients)
        // An unsubscribe link names the request in its subject, whatever address the list reads it at.
        let subject = snapshot.messages[0].subject
        snapshot.messages[0].cc = "x7f3k@em.example.com"
        snapshot.messages[0].subject = "Unsubscribe"
        #expect(AutomaticFollowUpCoordinator.evaluate(snapshot) == .automatedRecipients)
        snapshot.messages[0].subject = "Re: unsubscribe"
        #expect(AutomaticFollowUpCoordinator.candidate(in: snapshot)?.ownerEmail == "x7f3k@em.example.com")
        snapshot.messages[0].subject = subject
        snapshot.messages[0].cc = "Anna <anna@example.com>, Bob <bob@example.com>"
        snapshot.messages.append(fixture.message("reply", date: fixture.time - 1, sender: "bob@example.com"))
        #expect(AutomaticFollowUpCoordinator.candidate(in: snapshot) == nil)
        snapshot.labels["reply"] = [SystemLabel.draft]
        #expect(AutomaticFollowUpCoordinator.candidate(in: snapshot) != nil)
        snapshot.messages[0].cc = nil
        #expect(AutomaticFollowUpCoordinator.candidate(in: snapshot) == nil)
        snapshot.messages[0].recipients = "anna@example.com"
        snapshot.messages[0].sender = "stranger@example.com"
        #expect(AutomaticFollowUpCoordinator.candidate(in: snapshot) == nil)
    }

    @Test func startupAdoptsOldSentQuietlyAndFutureDueDoesNotDuplicateAfterRestart() async throws {
        let fixture = try await AutomaticFixture()
        let coordinator = fixture.coordinator()
        defer { coordinator.stop(); fixture.followUps.stop() }
        await coordinator.start(); await coordinator.waitForCurrentPass()
        var entries = try await fixture.store.commitmentEntries(accountIDs: ["a"])
        #expect(entries.count == 1)
        #expect(entries.first?.record.direction == .waitingFor)
        #expect(try await fixture.store.dueCommitmentReminders(accountIDs: ["a"], now: fixture.time).isEmpty)
        #expect(await fixture.scheduler.deliveries.isEmpty)
        #expect(fixture.preparedDraftIDs.isEmpty)

        // A new sent message starts a new waiting baseline; its later due time
        // can alert even though the originally adopted old message was quiet.
        let newer = fixture.message("new-sent", date: fixture.time, sender: "me@example.com", recipients: "anna@example.com")
        fixture.snapshot.messages.append(newer); fixture.snapshot.labels[newer.id] = [SystemLabel.sent]
        await coordinator.process(fixture.sync(newer)); await coordinator.waitForCurrentPass()
        entries = try await fixture.store.commitmentEntries(accountIDs: ["a"])
        #expect(entries.first?.reminders.first?.baselineMessageID == newer.id)
        fixture.time += 3 * 86_400 + 1
        await fixture.followUps.evaluateReminders()
        #expect(await fixture.scheduler.deliveries.count == 1)
        coordinator.stop()
        await coordinator.start(); await coordinator.waitForCurrentPass()
        await fixture.followUps.evaluateReminders()
        #expect(await fixture.scheduler.deliveries.count == 1)
    }

    @Test func disablingDuringScheduleRejectsTheAlertWhileManualDecisionsSurvive() async throws {
        let fixture = try await AutomaticFixture(enabledBefore: 10 * 86_400)
        let coordinator = fixture.coordinator()
        fixture.followUps.canDeliverAutomaticReminders = { coordinator.settingsReady }
        await fixture.scheduler.setCallback { @MainActor in fixture.preferences.automaticRemindersEnabled = false }
        defer { coordinator.stop(); fixture.followUps.stop() }
        await coordinator.start(); await coordinator.waitForCurrentPass()
        let delivered = try #require(await fixture.scheduler.deliveries.first?.id)
        #expect(await fixture.scheduler.removals.contains(delivered))
        var entry = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        #expect(entry.reminders.first?.deliveredAt == nil)
        await coordinator.preferencesChanged()
        #expect(try await fixture.store.dueCommitmentReminders(accountIDs: ["a"], now: fixture.time).isEmpty)
        entry = try #require(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first)
        entry = try await fixture.store.setCommitmentStatus(accountID: "a", id: entry.record.id, status: .dismissed,
            expectedRevision: entry.record.revision, now: fixture.time)
        fixture.preferences.automaticRemindersEnabled = true
        await coordinator.preferencesChanged(); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first?.record.status == .dismissed)
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).count == 1)
    }

    @Test func draftReservationIsOncePerOutgoingAndFailureDoesNotRetryOrSend() async throws {
        let fixture = try await AutomaticFixture(enabledBefore: 10 * 86_400)
        fixture.preferences.automaticDraftsEnabled = true
        fixture.failDraft = true
        let coordinator = fixture.coordinator()
        defer { coordinator.stop(); fixture.followUps.stop() }
        await coordinator.start(); await coordinator.waitForCurrentPass()
        #expect(fixture.preparedDraftIDs.count == 1)
        #expect(coordinator.draftErrorMessage != nil)
        fixture.failDraft = false
        coordinator.stop()
        await coordinator.start(); await coordinator.waitForCurrentPass()
        #expect(fixture.preparedDraftIDs.count == 1)
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).first?.record.status == .open)
    }

    @Test func replyPreventsAutomaticTrackingAndRevokedAccountCannotPublishARead() async throws {
        let fixture = try await AutomaticFixture()
        fixture.snapshot.messages.append(fixture.message("reply", date: fixture.time - 1, sender: "anna@example.com"))
        let coordinator = fixture.coordinator()
        defer { coordinator.stop(); fixture.followUps.stop() }
        await coordinator.start(); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).isEmpty)
        fixture.snapshot.messages.removeLast()
        fixture.onRead = { fixture.activeAccounts = [] }
        await coordinator.process(fixture.sync(fixture.snapshot.messages[0])); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).isEmpty)
    }

    @Test func failedStartupCandidateIsRetriedAfterConnectivityReturns() async throws {
        let fixture = try await AutomaticFixture()
        fixture.failRead = true
        let coordinator = fixture.coordinator()
        defer { coordinator.stop(); fixture.followUps.stop() }
        await coordinator.start(); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).isEmpty)
        fixture.failRead = false
        await coordinator.start(); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).count == 1)
    }

    @Test func followUpOnAnUnsubscribeRequestIsRemovedWithItsAlert() async throws {
        let fixture = try await AutomaticFixture(enabledBefore: 10 * 86_400)
        let coordinator = fixture.coordinator()
        defer { coordinator.stop(); fixture.followUps.stop() }
        await coordinator.start(); await coordinator.waitForCurrentPass()
        let delivered = try #require(await fixture.scheduler.deliveries.first?.id)
        // As if the follow-up had been made before Tern skipped these mailboxes.
        fixture.snapshot.messages[0].recipients = "news+unsubscribe@lists.example.com"
        await coordinator.process(fixture.sync(fixture.snapshot.messages[0])); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).isEmpty)
        #expect(try await fixture.store.automaticFollowUps(accountIDs: ["a"]).isEmpty)
        #expect(await fixture.scheduler.removals.contains(delivered))
    }

    @Test func concurrentPreferenceApplicationsFinishWithLatestPolicy() async throws {
        let fixture = try await AutomaticFixture()
        fixture.holdConfiguration = true
        let coordinator = fixture.coordinator()
        defer { coordinator.stop(); fixture.followUps.stop() }
        let startup = Task { await coordinator.start() }
        try await fixture.waitUntil { fixture.configurationContinuation != nil }
        fixture.preferences.delayDays = 7
        let changed = Task { await coordinator.preferencesChanged() }
        await Task.yield()
        #expect(fixture.appliedDelays.isEmpty)
        fixture.holdConfiguration = false
        fixture.configurationContinuation?.resume(); fixture.configurationContinuation = nil
        await startup.value; await changed.value; await coordinator.waitForCurrentPass()
        #expect(coordinator.settingsReady)
        #expect(fixture.appliedDelays == [3, 7])
        #expect(try await fixture.store.automaticFollowUps(accountIDs: ["a"]).first?.delayDays == 7)
    }

    @Test func newlyActiveAccountAdoptsExistingOverdueMailQuietly() async throws {
        let fixture = try await AutomaticFixture(enabledBefore: 10 * 86_400)
        fixture.snapshot.messages.append(fixture.message("initial-reply", date: fixture.time - 1, sender: "anna@example.com"))
        let coordinator = fixture.coordinator()
        defer { coordinator.stop(); fixture.followUps.stop() }
        await coordinator.start(); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).isEmpty)
        fixture.activeAccounts = []
        await coordinator.start()
        #expect(coordinator.settingsReady)
        fixture.snapshot.messages.removeLast()
        fixture.activeAccounts = ["a"]
        #expect(!coordinator.settingsReady)
        await coordinator.start(); await coordinator.waitForCurrentPass()
        #expect(try await fixture.store.commitmentEntries(accountIDs: ["a"]).count == 1)
        #expect(try await fixture.store.dueCommitmentReminders(accountIDs: ["a"], now: fixture.time).isEmpty)
        #expect(await fixture.scheduler.deliveries.isEmpty)
    }
}

@Suite @MainActor struct AutomaticFollowUpDraftServiceTests {
    @Test func generationUsesWholePermittedThreadAndOnlyProposalTool() async throws {
        let provider = AutomaticDraftProvider()
        let entry = draftEntry()
        let service = AutomaticFollowUpDraftService(session: session(provider: provider, truncated: false), isCurrent: { true })
        let proposal = try await service.proposal(for: entry, baselineMessageID: "sent")
        #expect(proposal.body == "Could you review the final proposal?")
        let request = try #require(await provider.requests.first)
        #expect(request.tools.map(\.name) == [ComposeAssistantProposal.definition.name])
        let encoded = try request.input[0].jsonString()
        #expect(encoded.contains("Earlier decision"))
        #expect(encoded.contains("Final proposal"))
        #expect(request.instructions.contains("short sentences"))
    }

    @Test func partialConversationCannotProduceAnAutomaticDraft() async throws {
        let provider = AutomaticDraftProvider()
        let service = AutomaticFollowUpDraftService(session: session(provider: provider, truncated: true), isCurrent: { true })
        await #expect(throws: AutomaticFollowUpError.self) {
            try await service.proposal(for: draftEntry(), baselineMessageID: "sent")
        }
        #expect(await provider.requests.isEmpty)
    }

    private func draftEntry() -> CommitmentEntry {
        CommitmentEntry(record: CommitmentRecord(accountID: "a", id: "commitment", threadID: "thread", sourceMessageID: "sent",
            sourceMessageDate: .now, sourceSubject: "Proposal", title: "Proposal", direction: .waitingFor))
    }

    private func session(provider: AutomaticDraftProvider, truncated: Bool) -> ComposeAssistantSession {
        let sources = ["earlier", "sent"].map {
            AssistantSource(accountID: "a", threadID: "thread", messageID: $0, partID: nil, title: "Proposal")
        }
        let data: AIJSON = .object([
            "total_messages": .number(2), "truncated": .bool(truncated),
            "messages": .array(["Earlier decision", "Final proposal"].map {
                .object(["text": .string($0), "truncated": .bool(false), "limitations": .array([])])
            }),
        ])
        return ComposeAssistantSession(provider: provider, model: "synthetic", scope: AssistantScopeSnapshot(accountIDs: ["a"], threadIDs: nil,
            accountInstances: [:], connectionRevision: 0, canUsePlan: true),
            tools: AssistantToolSession(definitions: [], execute: { call in
                #expect(call.name == "read_thread")
                return .init(data: data, sources: sources)
            }), isValid: { true }, writingStyle: { "Use short sentences." })
    }
}

@MainActor private final class AutomaticFixture {
    let store: AccountStore
    let preferences: FollowUpPreferences
    let scheduler = AutomaticTestScheduler()
    var time = Date(timeIntervalSince1970: 1_900_000_000)
    var snapshot: FollowUpThreadSnapshot
    var activeAccounts: Set<String> = ["a"]
    var preparedDraftIDs: [String] = []
    var failDraft = false
    var failRead = false
    var holdConfiguration = false
    var configurationContinuation: CheckedContinuation<Void, Never>?
    var appliedDelays: [Int] = []
    var onRead: (() -> Void)?
    let defaults: UserDefaults
    let suite: String
    lazy var followUps = FollowUpsModel(store: { self.store }, visibleAccountIDs: { self.activeAccounts }, canReadAccount: { self.activeAccounts.contains($0) },
        loadThread: { _, _ in
            self.onRead?()
            if self.failRead { throw AutomaticFollowUpError.unavailable }
            return self.snapshot
        }, prepareDraft: { _ in "manual" },
        scheduler: scheduler, now: { self.time })

    init(enabledBefore: TimeInterval = 0) async throws {
        store = try AccountStore.inMemory()
        suite = "automatic-coordinator-test-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let enabled = time - enabledBefore
        preferences = FollowUpPreferences(defaults: defaults, now: { enabled })
        let source = MessageRecord(accountID: "a", id: "sent", threadID: "thread", historyID: 100, date: time - 4 * 86_400,
            snippet: "", sender: "me@example.com", recipients: "Anna <anna@example.com>", cc: nil, subject: "Proposal", sizeEstimate: 1)
        snapshot = FollowUpThreadSnapshot(accountID: "a", threadID: "thread", messages: [source], labels: [source.id: [SystemLabel.sent]],
            ownAddresses: ["me@example.com", "alias@example.com"], checkedAt: time)
        try await store.save(AccountRecord(id: "a", email: "me@example.com", displayName: "Me", grantedScopes: [], addedAt: time))
        if enabledBefore > 0 {
            _ = try await store.configureAutomaticFollowUps(accountIDs: ["a"], enabled: true,
                delayDays: preferences.delayDays, enabledSince: enabled, now: enabled)
        }
    }

    func coordinator() -> AutomaticFollowUpCoordinator {
        AutomaticFollowUpCoordinator(preferences: preferences, followUps: followUps, store: { self.store }, accountIDs: { self.activeAccounts },
            cachedCandidates: { account, _, limit in
                #expect(limit == 100)
                return [ThreadKey(accountID: account, threadID: "thread")]
            }, canDraft: { self.activeAccounts.contains($0) }, prepareDraft: { _, receipt, authorization in
                guard await authorization.isValid() else { throw CancellationError() }
                self.preparedDraftIDs.append(receipt.draftID)
                if self.failDraft { throw AutomaticFollowUpError.incompleteConversation }
            }, now: { self.time }, configurePolicy: { store, all, active, enabled, days, since, date in
                if self.holdConfiguration { await withCheckedContinuation { self.configurationContinuation = $0 } }
                let result = try await store.configureAutomaticFollowUps(accountIDs: all, activeAccountIDs: active,
                    enabled: enabled, delayDays: days, enabledSince: since, now: date)
                self.appliedDelays.append(days)
                return result
            })
    }

    func message(_ id: String, date: Date, sender: String, recipients: String = "me@example.com") -> MessageRecord {
        MessageRecord(accountID: "a", id: id, threadID: "thread", historyID: 101, date: date, snippet: "", sender: sender,
            recipients: recipients, cc: nil, subject: "Re: Proposal", sizeEstimate: 1)
    }

    func sync(_ message: MessageRecord) -> MailSyncNotification {
        MailSyncNotification(accountID: "a", fromHistoryID: 100, toHistoryID: 101,
            messages: [MailNotificationMessage(record: message, labelIDs: snapshot.labels[message.id] ?? [], addedHistoryID: 101)])
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AutomaticFollowUpError.unavailable
    }
}

private actor AutomaticTestScheduler: FollowUpNotificationScheduling {
    private(set) var deliveries: [FollowUpNotification] = []
    private(set) var removals: [String] = []
    private var callback: (@Sendable () async -> Void)?
    func setCallback(_ value: @escaping @Sendable () async -> Void) { callback = value }
    func permission() async -> MailNotificationPermission { .allowed }
    func requestPermission() async throws -> Bool { true }
    func schedule(_ notification: FollowUpNotification) async throws { deliveries.append(notification); await callback?() }
    func remove(id: String) async { removals.append(id) }
    func removeAccount(_ accountID: String) async {}
}

private actor AutomaticDraftProvider: AIProvider {
    private(set) var requests: [AIRequest] = []
    func models() async throws -> [AIModel] { [.init(id: "synthetic", displayName: "Synthetic")] }
    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(request)
                let arguments = AIJSON.object(["subject": .string("Proposal"), "body": .string("Could you review the final proposal?")])
                do {
                    continuation.yield(.completed(AIResponse(output: [], text: "", toolCalls: [AIToolCall(id: "proposal", namespace: "tern",
                        name: "propose_composer_draft", arguments: try arguments.jsonString())])))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
    private func record(_ request: AIRequest) { requests.append(request) }
}
