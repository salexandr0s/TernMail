import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct MailOrganizationJobApplicationTests {
    @Test func rulesOnlyCreatesItsLabelAndFilterWithoutChangingExistingMessages() async throws {
        let fixture = try await JobApplicationFixture.make()
        let category = fixture.category(senders: ["new@example.com"], backfillExisting: false)
        #expect(category.messageIDs.count == fixture.samples.messages.count)
        let receipt = try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        let rows = try await fixture.rows()
        #expect(rows.map(\.kind) == [.createLabel, .createFilter])
        #expect(receipt.messageCount == 0 && receipt.filterCount == 1)
        while await fixture.engine.sendDueActions() > 0 {}
        while await fixture.engine.sendDueSettings() > 0 {}
        #expect(await fixture.gmail.changes.isEmpty)
        #expect(await fixture.gmail.labelCalls == ["create Reading"])
        #expect(await fixture.settings.rules == [.init(criteria: .init(from: "new@example.com"),
                                                      action: .init(addLabelIds: ["Label_1"]))])
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).isComplete)
        let repeated = try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        #expect(repeated.actionIDs.isEmpty && repeated.messageCount == 0 && repeated.filterCount == 0)
        #expect(await fixture.settings.filterIDs.count == 1)
        await fixture.engine.stop()
    }

    @Test func rulesOnlyStillRequiresAllOfItsSendersEvidence() async throws {
        let fixture = try await JobApplicationFixture.make()
        let category = OrganizationApplicationCategory(id: "reading", name: "Reading", kind: .topic,
            messageIDs: ["m2"], ruleSenders: ["new@example.com"], backfillExisting: false)
        await #expect(throws: OrganizationApplicationError.unsafeRule) {
            try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        }
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.gmail.labelCalls.isEmpty)
        await fixture.engine.stop()
    }

    @Test(arguments: [true, false])
    func noBackfillAndNoSelectedFutureActionCannotCreateAnEmptyLabel(createFilter: Bool) async throws {
        let fixture = try await JobApplicationFixture.make()
        let category = OrganizationApplicationCategory(id: "reading", name: "Reading", kind: .topic,
            messageIDs: fixture.samples.messages.map(\.messageID),
            ruleSenders: createFilter ? [] : ["new@example.com"], createFilter: createFilter, backfillExisting: false)
        await #expect(throws: OrganizationApplicationError.invalidSelection) {
            try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        }
        #expect(try await fixture.rows().isEmpty)
        await fixture.engine.stop()
    }

    @Test func mixedChoicesCountAndQueueOnlySelectedBackfillMessages() async throws {
        let fixture = try await JobApplicationFixture.make()
        let future = OrganizationApplicationCategory(id: "reading", name: "Reading", kind: .topic,
            messageIDs: ["m0", "m1"], ruleSenders: ["known@example.com"], backfillExisting: false)
        let existing = OrganizationApplicationCategory(id: "updates", name: "Updates", kind: .topic,
            messageIDs: ["m2", "m3"], ruleSenders: [], createFilter: false)
        let receipt = try await fixture.engine.applyOrganization(categories: [future, existing], samples: fixture.samples)
        let backfills = try await fixture.rows().filter { $0.kind == .modifyMessages }
        #expect(backfills.count == 1)
        #expect(backfills.first?.messageIDs == ["m2", "m3"])
        #expect(receipt.categoryCount == 2 && receipt.messageCount == 2 && receipt.filterCount == 1)
        await fixture.engine.stop()
    }

    @Test func expandingAnExistingLabelPreservesItsRulesAndAddsOnlyMissingSenders() async throws {
        let label = try jobLabel("Reading")
        let original = GmailFilter(id: "original", criteria: .init(from: "known@example.com"),
            action: .init(addLabelIds: [label.id], removeLabelIds: [SystemLabel.inbox], forward: "archive@example.com"))
        let fixture = try await JobApplicationFixture.make(label: label, filters: [original])
        let coverage = fixture.samples.ruleCoverage(existingLabelID: label.id, labelName: label.name,
            proposedSenders: ["known@example.com", "new@example.com"])
        #expect(coverage.existingRuleCount == 1)
        #expect(coverage.alreadyCoveredSenders == ["known@example.com"])
        #expect(coverage.newSenders == ["new@example.com"])
        let category = fixture.category(senders: ["known@example.com", "new@example.com"], existingLabelID: label.id)
        let receipt = try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        #expect(receipt.filterCount == 1)
        while await fixture.engine.sendDueActions() > 0 {}
        while await fixture.engine.sendDueSettings() > 0 {}
        let rules = await fixture.settings.rules
        #expect(rules.count == 2)
        #expect(rules.contains(.init(criteria: original.criteria, action: original.action)))
        #expect(rules.contains(.init(criteria: .init(from: "new@example.com"), action: .init(addLabelIds: [label.id]))))
        #expect(await fixture.gmail.labelCalls.isEmpty)
        #expect(try await fixture.engine.organizationApplicationStatus(receipt).isComplete)
        await fixture.engine.stop()
    }

    @Test(arguments: [true, false])
    func staleExistingLabelIdentityFailsBeforeAnyChangesAreQueued(deleted: Bool) async throws {
        let original = try jobLabel("Reading")
        let fixture = try await JobApplicationFixture.make(label: original)
        await fixture.gmail.setLabels(deleted ? [] : [try jobLabel("Renamed")])
        await #expect(throws: OrganizationApplicationError.staleLabels) {
            try await fixture.engine.applyOrganization(categories: [fixture.category(existingLabelID: original.id)],
                                                       samples: fixture.samples)
        }
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.gmail.labelCalls.isEmpty)
        await fixture.engine.stop()
    }

    @Test func largeSelectionsQueueBoundedMessageRowsAndReuseThemOnRepeatedApply() async throws {
        let fixture = try await JobApplicationFixture.make(messageCount: 1_001)
        let category = fixture.category()
        let first = try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        let second = try await fixture.engine.applyOrganization(categories: [category], samples: fixture.samples)
        let rows = try await fixture.rows()
        let messages = rows.filter { $0.kind == .modifyMessages }
        #expect(messages.map(\.messageIDs.count).sorted() == [1, 1_000])
        #expect(Set(messages.flatMap(\.messageIDs)).count == 1_001)
        #expect(first.actionIDs == second.actionIDs)
        #expect(first.messageCount == 1_001)
        await fixture.engine.stop()
    }

    @Test func pendingFilterCreationsReserveTheRemainingGmailCapacity() async throws {
        let existing = (0..<999).map {
            GmailFilter(id: "old\($0)", criteria: .init(from: "other\($0)@example.com"),
                        action: .init(addLabelIds: [SystemLabel.starred]))
        }
        let fixture = try await JobApplicationFixture.make(filters: existing)
        _ = try await fixture.engine.createFilter(.init(criteria: .init(from: "pending@example.com"),
                                                        action: .init(addLabelIds: [SystemLabel.starred])))
        await #expect(throws: OrganizationApplicationError.filterLimitReached) {
            try await fixture.engine.applyOrganization(categories: [fixture.category(senders: ["new@example.com"])],
                                                       samples: fixture.samples)
        }
        let rows = try await fixture.rows()
        #expect(rows.count == 1 && rows[0].kind == .createFilter)
        #expect(await fixture.gmail.labelCalls.isEmpty)
        await fixture.engine.stop()
    }

    @Test func aPendingRuleDeletionCannotBeAdoptedAsFutureCoverage() async throws {
        let label = try jobLabel("Reading")
        let original = GmailFilter(id: "original", criteria: .init(from: "known@example.com"),
                                   action: .init(addLabelIds: [label.id]))
        let fixture = try await JobApplicationFixture.make(label: label, filters: [original])
        _ = try await fixture.engine.deleteFilter(original)
        await #expect(throws: OrganizationApplicationError.conflictingChange) {
            try await fixture.engine.applyOrganization(
                categories: [fixture.category(senders: ["known@example.com"], existingLabelID: label.id)],
                samples: fixture.samples)
        }
        let rows = try await fixture.rows()
        #expect(rows.count == 1 && rows[0].kind == .deleteFilter)
        await fixture.engine.stop()
    }

    @Test func externallyDeletedReviewedCoverageDoesNotBecomeANewUnreviewedFilter() async throws {
        let label = try jobLabel("Reading")
        let original = GmailFilter(id: "original", criteria: .init(from: "known@example.com"),
                                   action: .init(addLabelIds: [label.id]))
        let fixture = try await JobApplicationFixture.make(label: label, filters: [original])
        try await fixture.settings.deleteFilter(id: "original")
        await #expect(throws: OrganizationApplicationError.staleRules) {
            try await fixture.engine.applyOrganization(
                categories: [fixture.category(senders: ["known@example.com"], existingLabelID: label.id)],
                samples: fixture.samples)
        }
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.settings.filterIDs.isEmpty)
        await fixture.engine.stop()
    }

    @Test func additionalCriteriaDoNotPretendToCoverAllMailFromASender() {
        let filter = GmailFilter(id: "limited", criteria: .init(from: "known@example.com", subject: "Invoice"),
                                 action: .init(addLabelIds: ["label"]))
        let coverage = OrganizationRuleCoverage(labelID: "label", proposedSenders: ["known@example.com"],
                                               existingFilters: [filter])
        #expect(coverage.existingRuleCount == 1)
        #expect(coverage.alreadyCoveredSenders.isEmpty)
        #expect(coverage.newFilterCount == 1)
    }

    @Test func senderEvidenceUsesMessagesBeyondTheFirstAnalysisBatch() {
        let messages = (0..<301).map { index in
            MailOrganizationSample(messageID: "m\(index)", threadID: "t\(index)", sender: "known@example.com",
                recipients: ["me@example.com"], subject: "Updates", snippet: "", date: .now, isSent: false,
                labelIDs: [], hasMailingListHeaders: index != 300)
        }
        let sample = MailOrganizationSamples(accountID: "account", messages: messages, existingLabels: [],
            selectedCount: messages.count, unavailableCount: 0, isPartial: false)
        #expect(sample.eligibleRuleSenders(["known@example.com"], selectedMessageIDs: Set(messages.map(\.messageID))).isEmpty)
        let clean = Array(messages.prefix(300))
        let complete = MailOrganizationSamples(accountID: "account", messages: clean, existingLabels: [],
            selectedCount: clean.count, unavailableCount: 0, isPartial: false)
        #expect(complete.eligibleRuleSenders(["known@example.com"], selectedMessageIDs: Set(clean.map(\.messageID))) == ["known@example.com"])
    }
}

private struct JobApplicationFixture {
    let engine: SyncEngine
    let cache: MailCache
    let gmail: FakeGmail
    let settings: FakeSettings
    let samples: MailOrganizationSamples

    static func make(messageCount: Int = 4, label: GmailLabel? = nil,
                     filters: [GmailFilter] = []) async throws -> JobApplicationFixture {
        let cache = try MailCache.inMemory()
        let gmail = FakeGmail()
        if let label { await gmail.setLabels([label]) }
        let settings = FakeSettings(filters: filters, vacation: .init())
        let messages = (0..<messageCount).map { index in
            MailOrganizationSample(messageID: "m\(index)", threadID: "t\(index)",
                sender: index < 2 ? "known@example.com" : "new@example.com", recipients: ["me@example.com"],
                subject: "Updates", snippet: "", date: Date(timeIntervalSince1970: 1_700_000_000), isSent: false,
                labelIDs: [SystemLabel.inbox], hasMailingListHeaders: true)
        }
        try await cache.write { tx in
            let updates = messages.map { sample in
                CacheTransaction.MessageUpdate(record: MessageRecord(accountID: "account", id: sample.messageID,
                    threadID: sample.threadID, historyID: 1, date: sample.date ?? .distantPast,
                    snippet: "", sender: sample.sender, recipients: "me@example.com", cc: nil,
                    subject: sample.subject, sizeEstimate: 0), labelIDs: sample.labelIDs)
            }
            try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: "account")
        }
        let engine = SyncEngine(accountID: "account", sender: .init(address: "me@example.com"),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernOrganizationJob-\(UUID().uuidString)"),
            gmail: gmail, settings: settings, cache: cache, sendsAutomatically: false,
            indexesAttachmentsAutomatically: false)
        let samples = MailOrganizationSamples(accountID: "account", messages: messages,
            existingLabels: label.map { [$0] } ?? [], selectedCount: messageCount, unavailableCount: 0,
            isPartial: false, existingFilters: filters, filterContextAvailable: true)
        return .init(engine: engine, cache: cache, gmail: gmail, settings: settings, samples: samples)
    }

    func category(senders: [String] = [], existingLabelID: String? = nil,
                  backfillExisting: Bool = true) -> OrganizationApplicationCategory {
        .init(id: "reading", name: "Reading", kind: .topic, messageIDs: samples.messages.map(\.messageID),
              ruleSenders: senders, createFilter: !senders.isEmpty, existingLabelID: existingLabelID,
              backfillExisting: backfillExisting)
    }

    func rows() async throws -> [PendingAction] { try await cache.read { try $0.allActions(accountID: "account") } }
}

private func jobLabel(_ name: String) throws -> GmailLabel {
    let data = try JSONSerialization.data(withJSONObject: ["id": "Label_reading", "name": name, "type": "user"])
    return try JSONDecoder().decode(GmailLabel.self, from: data)
}
