import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct MailOrganizationApplicationTests {
    @Test func newLabelsReachGmailBeforeFiltersAndBackfillOnlyReviewedMessages() async throws {
        let fixture = try await Fixture.make()
        let receipt = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        #expect(receipt.categoryCount == 1)
        #expect(receipt.messageCount == 2)
        #expect(receipt.filterCount == 1)
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).pendingCount == 3)
        #expect(await fixture.engine.sendDueSettings() == 0)
        #expect(await fixture.settings.calls.isEmpty)

        #expect(await fixture.engine.sendDueActions() == 1)
        #expect(await fixture.gmail.changes.isEmpty)
        #expect(await fixture.engine.sendDueSettings() == 1)
        #expect(await fixture.settings.rules == [GmailFilter(criteria: .init(from: "news@example.com"),
                                                             action: .init(addLabelIds: ["Label_1"]))])
        #expect(await fixture.engine.sendDueActions() == 1)
        #expect(await fixture.gmail.changes == [Change("batchModify", ["m1", "m2"], add: ["Label_1"])])
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).isComplete)
        try await fixture.cache.write { tx in
            try tx.dropSentActions(confirmedThrough: Int64.max, passStart: .distantFuture, accountID: account)
        }
        // Queue pruning cannot turn delivered work into a pending or unknown result.
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).sentCount == 3)
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).isComplete)
        await fixture.engine.stop()
    }

    @Test func repeatedApplyReusesPendingLabelsAndFilters() async throws {
        let fixture = try await Fixture.make()
        let first = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        let second = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        #expect(first.actionIDs == second.actionIDs)
        #expect(try await fixture.rows().count == 3)
        while await fixture.engine.sendDueActions() > 0 {}
        while await fixture.engine.sendDueSettings() > 0 {}
        #expect(await fixture.gmail.labelCalls == ["create Newsletters"])
        #expect(await fixture.settings.filterIDs.count == 1)
        try await fixture.cache.write { tx in
            try tx.dropSentActions(confirmedThrough: Int64.max, passStart: .distantFuture, accountID: account)
        }
        #expect(try await fixture.engine.organizationApplicationStatus(first).isComplete)
        #expect(try await fixture.engine.organizationApplicationStatus(second).isComplete)
        await fixture.engine.stop()
    }

    @Test func reusingAQueuedLabelKeepsItsOriginalUndoOwnership() async throws {
        let fixture = try await Fixture.make()
        let original = try await fixture.engine.createLabel(named: "Newsletters", color: nil)
        _ = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        // Another client creates the same name before the queued request arrives.
        let existing = try JSONDecoder().decode(GmailLabel.self, from: Data(#"{"id":"Label_existing","name":"Newsletters","type":"user"}"#.utf8))
        await fixture.gmail.setLabels([existing])
        while await fixture.engine.sendDueActions() > 0 {}
        while await fixture.engine.sendDueSettings() > 0 {}
        try await fixture.cache.write { tx in
            try tx.dropSentActions(confirmedThrough: Int64.max, passStart: .distantFuture, accountID: account)
        }
        #expect(original.actions.first?.labelChange?.adoptedExisting == true)
        try await fixture.engine.undo(original)
        while await fixture.engine.sendDueActions() > 0 {}
        #expect(try await fixture.gmail.labels().map(\.id) == ["Label_existing"])
        #expect(await fixture.gmail.labelCalls == ["create Newsletters"])
        await fixture.engine.stop()
    }

    @Test func existingGmailLabelsAndFiltersAreAdopted() async throws {
        let fixture = try await Fixture.make()
        let label = try JSONDecoder().decode(GmailLabel.self, from: Data(#"{"id":"Label_existing","name":"Newsletters","type":"user"}"#.utf8))
        await fixture.gmail.setLabels([label])
        _ = try await fixture.settings.createFilter(criteria: .init(from: "news@example.com"),
                                                    action: .init(addLabelIds: [label.id]))
        let receipt = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        while await fixture.engine.sendDueActions() > 0 {}
        while await fixture.engine.sendDueSettings() > 0 {}
        #expect(await fixture.gmail.labelCalls.isEmpty)
        #expect(await fixture.settings.filterIDs.count == 1)
        #expect(await fixture.settings.calls == ["create", "list"])
        #expect(await fixture.gmail.changes == [Change("batchModify", ["m1", "m2"], add: ["Label_existing"])])
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).isComplete)
        await fixture.engine.stop()
    }

    @Test func aLostFilterAnswerIsReconciledAfterRestart() async throws {
        let fixture = try await Fixture.make()
        _ = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        while await fixture.engine.sendDueActions() > 0 {}
        await fixture.settings.loseAnswer("create")
        #expect(await fixture.engine.sendDueSettings() == 1)
        #expect(await fixture.settings.filterIDs.count == 1)
        await fixture.engine.stop()
        try await fixture.cache.write { tx in try tx.requeueInterruptedActions(accountID: account) }
        fixture.clock.advance(3)
        let restarted = fixture.newEngine()
        #expect(await restarted.sendDueSettings() == 1)
        #expect(await fixture.settings.calls == ["list", "create", "list"])
        #expect(await fixture.settings.filterIDs.count == 1)
        #expect(try await fixture.rows().allSatisfy { $0.state == .sent })
        await restarted.stop()
    }

    @Test func refusedLabelKeepsDependentMessagesAndFilterVisibleForRetry() async throws {
        let fixture = try await Fixture.make()
        let receipt = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        await fixture.gmail.failNextLabelCall("create", with: .http(status: 400, reason: "invalidArgument"))
        #expect(await fixture.engine.sendDueActions() == 1)
        #expect(await fixture.engine.sendDueSettings() == 0)
        #expect(await fixture.settings.calls.isEmpty)
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).failedCount == 3)
        let rows = try await fixture.rows()
        let labelID = try #require(rows.first { $0.kind == .createLabel }?.id)
        let filterID = try #require(rows.first { $0.kind == .createFilter }?.id)
        let messageID = try #require(rows.first { $0.kind == .modifyMessages }?.id)
        await #expect(throws: FailedActionError.conflictingWork) {
            try await fixture.engine.retryFailedAction(id: filterID)
        }
        #expect(try await fixture.engine.retryFailedAction(id: labelID))
        #expect(await fixture.engine.sendDueActions() == 1)
        #expect(try await fixture.engine.retryFailedAction(id: filterID))
        #expect(try await fixture.engine.retryFailedAction(id: messageID))
        while await fixture.engine.sendDueActions() > 0 {}
        while await fixture.engine.sendDueSettings() > 0 {}
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).isComplete)
        #expect(await fixture.settings.rules.first?.action.addLabelIds == ["Label_1"])
        await fixture.engine.stop()
    }

    @Test func aFilterFailureReportsTheBackfillThatAlreadySucceeded() async throws {
        let fixture = try await Fixture.make()
        let receipt = try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        while await fixture.engine.sendDueActions() > 0 {}
        await fixture.settings.fail("create", with: .http(status: 403, reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT"))
        #expect(await fixture.engine.sendDueSettings() == 1)
        let status = try await fixture.engine.organizationApplicationStatus(receipt)
        #expect(status.sentCount == 2)
        #expect(status.failedCount == 1)
        #expect(!status.isComplete)
        #expect(await fixture.gmail.changes == [Change("batchModify", ["m1", "m2"], add: ["Label_1"])])
        await fixture.engine.stop()
    }

    @Test func aNewReplyDuringReviewInvalidatesWorkflowLabels() async throws {
        let fixture = try await Fixture.make()
        try await fixture.cache.write { tx in
            let reply = MessageRecord(accountID: account, id: "reply", threadID: "t1", historyID: 2,
                date: baseDate.addingTimeInterval(60), snippet: "", sender: "me@example.com",
                recipients: "news@example.com", cc: nil, subject: "Re: Issue", sizeEstimate: 0)
            try tx.rebuildThreads(try tx.upsertMessages([.init(record: reply, labelIDs: [SystemLabel.sent])]), accountID: account)
        }
        let action = OrganizationApplicationCategory(id: "action", name: "Action", kind: .action,
                                                     messageIDs: ["m1"], ruleSenders: [])
        await #expect(throws: OrganizationApplicationError.staleSamples) {
            try await fixture.engine.applyOrganization(categories: [action], samples: fixture.samples)
        }
        #expect(try await fixture.rows().isEmpty)
        await fixture.engine.stop()
    }

    @Test func pausedSettingsCannotBlockLabelDeletionOrEraseAnExplicitFilterDeletion() async throws {
        let fixture = try await Fixture.make()
        let label = try JSONDecoder().decode(GmailLabel.self, from: Data(#"{"id":"Label_old","name":"Old","type":"user"}"#.utf8))
        await fixture.gmail.setLabels([label])
        try await fixture.cache.write { tx in
            try tx.saveLabels([Mapping.label(label, accountID: account)], accountID: account)
        }
        let old = try await fixture.settings.createFilter(criteria: .init(from: "old@example.com"),
                                                         action: .init(addLabelIds: [label.id]))
        let accounts = try AccountStore.inMemory()
        try await accounts.save(.init(id: account, email: "me@example.com", displayName: "Me",
            grantedScopes: GoogleScopes.base + [GoogleScopes.gmailSettings], addedAt: .now, enabledFeatures: []))
        let engine = fixture.newEngine(accounts: accounts)
        _ = try await engine.createFilter(.init(criteria: .init(from: "new@example.com"), action: old.action))
        try await engine.deleteLabel(label.id)
        _ = try await engine.deleteFilter(old)
        #expect(await engine.sendDueSettings() == 0)
        #expect(await engine.sendDueActions() == 1)
        #expect(try await fixture.gmail.labels().isEmpty)
        let rows = try await fixture.rows()
        #expect(rows.first { $0.kind == .createFilter }?.state == .failed)
        #expect(rows.first { $0.kind == .deleteFilter }?.state == .queued)
        try await accounts.updateAccount(id: account) { $0.enabledFeatures = [AccountFeature.gmailSettings.rawValue] }
        #expect(await engine.sendDueSettings() == 1)
        #expect(await fixture.settings.filterIDs.isEmpty)
        await engine.stop()
        await fixture.engine.stop()
    }

    @Test func replacingAFilterCanRemoveALabelThatWasDeleted() async throws {
        let fixture = try await Fixture.make()
        let label = try JSONDecoder().decode(GmailLabel.self, from: Data(#"{"id":"Label_old","name":"Old","type":"user"}"#.utf8))
        await fixture.gmail.setLabels([label])
        try await fixture.cache.write { tx in
            try tx.saveLabels([Mapping.label(label, accountID: account)], accountID: account)
        }
        let old = try await fixture.settings.createFilter(criteria: .init(from: "old@example.com"),
                                                         action: .init(addLabelIds: [label.id]))
        let replacement = GmailFilter(criteria: old.criteria, action: .init(addLabelIds: [SystemLabel.starred]))
        try await fixture.engine.deleteLabel(label.id)
        _ = try await fixture.engine.replaceFilter(old, with: replacement)
        #expect(await fixture.engine.sendDueActions() == 1)
        #expect(await fixture.engine.sendDueSettings() == 1)
        #expect(await fixture.settings.rules == [replacement])
        await fixture.engine.stop()
    }

    @Test func invalidSelectionAndUnsafeRulesNeverQueuePartialWork() async throws {
        let fixture = try await Fixture.make()
        let invalid: [OrganizationApplicationCategory] = [
            .init(id: "x", name: "Inbox", kind: .topic, messageIDs: ["m1"], ruleSenders: []),
            .init(id: "x", name: "Unknown", kind: .topic, messageIDs: ["invented"], ruleSenders: []),
            .init(id: "x", name: "Action", kind: .action, messageIDs: ["m1", "m2"], ruleSenders: ["news@example.com"]),
            .init(id: "x", name: "Action", kind: .topic, messageIDs: ["m1", "m2"], ruleSenders: ["news@example.com"]),
            .init(id: "x", name: "Mixed", kind: .topic, messageIDs: ["m1"], ruleSenders: ["news@example.com"]),
            .init(id: "x", name: "Injected", kind: .topic, messageIDs: ["m1", "m2"], ruleSenders: ["news@example.com OR from:other@example.com"]),
        ]
        for category in invalid {
            await #expect(throws: OrganizationApplicationError.self) {
                try await fixture.engine.applyOrganization(categories: [fixture.news, category], samples: fixture.samples)
            }
        }
        let partial = MailOrganizationSamples(accountID: account, messages: fixture.samples.messages, existingLabels: [],
                                             selectedCount: 4, unavailableCount: 1, isPartial: true)
        await #expect(throws: OrganizationApplicationError.unsafeRule) {
            try await fixture.engine.applyOrganization(categories: [fixture.news], samples: partial)
        }
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.gmail.labelCalls.isEmpty)
        await fixture.engine.stop()
    }

    @Test func personalCorrespondenceAndSingleThreadRepetitionCannotBecomeSenderFilters() async throws {
        let fixture = try await Fixture.make()
        let recurring = [evidenceSample("m1", thread: "t1"), evidenceSample("m2", thread: "t2")]
        let cases: [[MailOrganizationSample]] = [
            [evidenceSample("m1", thread: "t1", list: false), evidenceSample("m2", thread: "t2", list: false)],
            [evidenceSample("m1", thread: "t1"), evidenceSample("m2", thread: "t1")],
            [evidenceSample("m1", thread: "t1"), evidenceSample("m2", thread: "t2", list: false)],
            recurring + [evidenceSample("sent", thread: "outgoing", recipients: ["NEWS@example.com"], isSent: true)],
            recurring + [evidenceSample("reply", thread: "t1", recipients: ["someone@example.com"], isSent: true)],
        ]
        for messages in cases {
            let samples = MailOrganizationSamples(accountID: account, messages: messages, existingLabels: [],
                selectedCount: messages.count, unavailableCount: 0, isPartial: false)
            await #expect(throws: OrganizationApplicationError.unsafeRule) {
                try await fixture.engine.applyOrganization(categories: [fixture.news], samples: samples)
            }
        }
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.gmail.labelCalls.isEmpty)
        #expect(await fixture.settings.calls.isEmpty)
        await fixture.engine.stop()
    }

    @Test func workflowLabelsRequireOneNewestKnownTimestamp() async throws {
        let fixture = try await Fixture.make()
        let action = OrganizationApplicationCategory(id: "action", name: "Action", kind: .action,
                                                     messageIDs: ["m1"], ruleSenders: [])
        let cases: [[MailOrganizationSample]] = [
            [evidenceSample("m1", thread: "t1", date: nil)],
            [evidenceSample("m1", thread: "t1"), evidenceSample("m3", thread: "t1")],
            [evidenceSample("m1", thread: "t1"), evidenceSample("m3", thread: "t1", date: nil)],
        ]
        for messages in cases {
            let samples = MailOrganizationSamples(accountID: account, messages: messages, existingLabels: [],
                selectedCount: messages.count, unavailableCount: 0, isPartial: false)
            await #expect(throws: OrganizationApplicationError.staleSamples) {
                try await fixture.engine.applyOrganization(categories: [action], samples: samples)
            }
        }
        #expect(try await fixture.rows().isEmpty)
        await fixture.engine.stop()
    }

    @Test func unicodeLabelNormalizationDoesNotRejectAValidCategory() async throws {
        let fixture = try await Fixture.make()
        let name = String(repeating: "İ", count: 110)
        let id = "category:" + name.precomposedStringWithCanonicalMapping.lowercased()
        #expect(name.utf8.count <= 225 && id.utf8.count > 256)
        let category = OrganizationApplicationCategory(id: id, name: name, kind: .topic,
            messageIDs: ["m1"], ruleSenders: [], createFilter: false)
        _ = try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        #expect(try await fixture.rows().map(\.kind) == [.createLabel, .modifyMessages])
        await fixture.engine.stop()
    }

    @Test func accountIdentityConsentAndSettingsPermissionAreRecheckedBeforeQueueing() async throws {
        let fixture = try await Fixture.make()
        let other = MailOrganizationSamples(accountID: "other", messages: fixture.samples.messages, existingLabels: [],
                                           selectedCount: 3, unavailableCount: 0, isPartial: false)
        await #expect(throws: OrganizationApplicationError.accountMismatch) {
            try await fixture.engine.applyOrganization(categories: [fixture.news], samples: other)
        }
        await #expect(throws: AssistantMailError.accessChanged) {
            try await fixture.engine.applyOrganization(categories: [fixture.news], samples: fixture.samples, isAuthorized: { false })
        }
        let accounts = try AccountStore.inMemory()
        try await accounts.save(.init(id: account, email: "me@example.com", displayName: "Me", grantedScopes: GoogleScopes.base,
                                      addedAt: .now, enabledFeatures: []))
        let withoutSettings = fixture.newEngine(accounts: accounts)
        await #expect(throws: OrganizationApplicationError.settingsPermissionRequired) {
            try await withoutSettings.applyOrganization(categories: [fixture.news], samples: fixture.samples)
        }
        let labelsOnly = OrganizationApplicationCategory(id: "news", name: "Newsletters", kind: .topic,
                                                        messageIDs: ["m1", "m2"], ruleSenders: [], createFilter: false)
        _ = try await withoutSettings.applyOrganization(categories: [labelsOnly], samples: fixture.samples)
        #expect(try await fixture.rows().map(\.kind) == [.createLabel, .modifyMessages])
        await withoutSettings.stop()
        await fixture.engine.stop()
    }
}

private struct Fixture {
    let engine: SyncEngine
    let cache: MailCache
    let gmail: FakeGmail
    let settings: FakeSettings
    let clock: TestClock
    let samples: MailOrganizationSamples
    var news: OrganizationApplicationCategory {
        .init(id: "news", name: "Newsletters", kind: .topic, messageIDs: ["m1", "m2"], ruleSenders: ["news@example.com"])
    }

    static func make() async throws -> Fixture {
        let cache = try MailCache.inMemory()
        let gmail = FakeGmail()
        let settings = FakeSettings(filters: [], vacation: .init())
        let clock = TestClock()
        let messages = (1...3).map { index in
            MailOrganizationSample(messageID: "m\(index)", threadID: index == 2 ? "t2" : "t1",
                sender: index == 3 ? "other@example.com" : "news@example.com", recipients: ["me@example.com"],
                subject: "Issue", snippet: "", date: index == 3 ? baseDate.addingTimeInterval(-60) : baseDate,
                isSent: false, labelIDs: [SystemLabel.inbox], hasMailingListHeaders: index < 3)
        }
        try await cache.write { tx in
            let updates = messages.map { sample in
                CacheTransaction.MessageUpdate(record: MessageRecord(accountID: account, id: sample.messageID,
                    threadID: sample.threadID, historyID: 1, date: sample.date ?? baseDate, snippet: "", sender: sample.sender,
                    recipients: "me@example.com", cc: nil, subject: "Issue", sizeEstimate: 0), labelIDs: sample.labelIDs)
            }
            try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: account)
        }
        let engine = makeEngine(cache: cache, gmail: gmail, settings: settings, clock: clock)
        return Fixture(engine: engine, cache: cache, gmail: gmail, settings: settings, clock: clock,
            samples: .init(accountID: account, messages: messages, existingLabels: [], selectedCount: 3,
                           unavailableCount: 0, isPartial: false))
    }

    func rows() async throws -> [PendingAction] {
        try await cache.read { tx in try tx.allActions(accountID: account) }
    }

    func newEngine(accounts: AccountStore? = nil) -> SyncEngine {
        Self.makeEngine(cache: cache, gmail: gmail, settings: settings, clock: clock, accounts: accounts)
    }

    private static func makeEngine(cache: MailCache, gmail: FakeGmail, settings: FakeSettings,
                                   clock: TestClock, accounts: AccountStore? = nil) -> SyncEngine {
        SyncEngine(accountID: account, sender: .init(address: "me@example.com"),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernOrganization-\(UUID().uuidString)"),
            gmail: gmail, settings: settings, accounts: accounts, cache: cache, sendsAutomatically: false,
            indexesAttachmentsAutomatically: false, now: clock.now)
    }
}

private func evidenceSample(_ id: String, thread: String, recipients: [String] = ["me@example.com"],
                            date: Date? = baseDate, isSent: Bool = false, list: Bool = true) -> MailOrganizationSample {
    .init(messageID: id, threadID: thread, sender: isSent ? "me@example.com" : "news@example.com", recipients: recipients,
          subject: "Issue", snippet: "", date: date, isSent: isSent, labelIDs: [isSent ? SystemLabel.sent : SystemLabel.inbox],
          hasMailingListHeaders: list)
}
