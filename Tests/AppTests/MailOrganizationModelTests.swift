import Foundation
import GmailAPI
import Observation
import Testing
import TernAI
@testable import SyncEngine
@testable import Tern

@Suite @MainActor struct MailOrganizationModelTests {
    @Test func rulesOnlySelectionKeepsEvidenceWithoutBackfillingMessages() async throws {
        let harness = OrganizationModelHarness()
        let model = harness.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        model.categories[0].setBackfill(false)
        model.categories[1].setBackfill(false)
        #expect(model.selectedMessageCount == 0)
        #expect(model.selectedFilterCount == 1 && model.selectedRuleSuggestionCount == 1)
        #expect(model.canApply)
        model.applySelection()
        await model.waitForOperation()
        let selected = try #require(harness.applied.first)
        #expect(selected.count == 1 && selected[0].createFilter)
        #expect(!selected[0].backfillExisting)
        #expect(selected[0].messageIDs == ["m1", "m2"])
        #expect(model.receipt?.messageCount == 0)
    }

    @Test func independentActionsDoNotRestoreHiddenSelections() {
        var category = MailOrganizationReviewCategory(OrganizationModelHarness.plan.categories[0], canCreateFilters: true)
        category.setBackfill(false)
        #expect(category.isSelected && category.createsFilter && !category.backfillExisting)
        category.setFutureMail(false)
        #expect(!category.isSelected && !category.createsFilter && !category.backfillExisting)
        category.setBackfill(true)
        #expect(category.isSelected && !category.createsFilter && category.backfillExisting)
        category.setFutureMail(true)
        #expect(category.isSelected && category.createsFilter && category.backfillExisting)
        category.isSelected = false
        category.setBackfill(true)
        #expect(category.isSelected && !category.createsFilter && category.backfillExisting)
        category.isSelected = false
        category.setFutureMail(true)
        #expect(category.isSelected && category.createsFilter && !category.backfillExisting)
    }

    @Test(arguments: [true, false])
    func bulkSelectionRestoresOnlyPermittedActions(canCreateFilters: Bool) async {
        let model = OrganizationModelHarness(canCreateFilters: canCreateFilters).makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        model.setAllSuggestionsSelected(false)
        #expect(model.selectedCount == 0 && !model.canApply)
        #expect(model.categories.allSatisfy { !$0.isSelected && !$0.createsFilter && !$0.backfillExisting })
        model.setAllSuggestionsSelected(true)
        #expect(model.selectedCount == 2 && model.selectedMessageCount == 3)
        #expect(model.categories.allSatisfy { $0.isSelected && $0.backfillExisting })
        #expect(model.categories[0].createsFilter == canCreateFilters)
        #expect(!model.categories[1].createsFilter && model.canApply)
    }

    @Test func alreadyCoveredRulesDoNotLeaveAnInvisibleSelectedAction() async throws {
        let label = try JSONDecoder().decode(GmailLabel.self,
            from: Data(#"{"id":"Label_news","name":"Newsletters","type":"user"}"#.utf8))
        let filter = GmailFilter(id: "Filter_news", criteria: .init(from: "news@example.invalid"),
                                 action: .init(addLabelIds: [label.id]))
        let model = OrganizationModelHarness(existingLabels: [label], existingFilters: [filter]).makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        #expect(!model.categories[0].createsFilter)
        model.categories[0].setBackfill(false)
        #expect(!model.categories[0].isSelected && model.canApply)
        model.categories[1].setBackfill(false)
        #expect(model.selectedCount == 0 && !model.canApply)
        model.categories[0].setFutureMail(true)
        #expect(!model.canApply)
    }

    @Test(arguments: [0, 1, 3])
    func smallerMailboxesUseActualCountAndEmptyMailSkipsAnalysis(messageCount: Int) async {
        let harness = OrganizationModelHarness(messageCount: messageCount)
        let analyzed = OrganizationAnalyzedCounts()
        var limits: [Int] = []
        let model = harness.makeModel(readJobSamples: { _, maximum, _, _ in
            limits.append(maximum)
            return harness.samples
        }, analyzeJob: { samples, _, _, _, _, _ in
            await analyzed.record(samples.messages.count)
            return .init(categories: [], analyzedCount: samples.messages.count)
        })
        model.startAnalysis()
        await model.waitForOperation()
        #expect(limits == [5_000])
        #expect(await analyzed.counts == (messageCount == 0 ? [] : [messageCount]))
        #expect(model.phase == .review && model.errorMessage == nil)
        #expect(model.samples?.messages.count == messageCount)
        #expect(!model.canApply && !model.canResumeAnalysis)
    }

    @Test(arguments: [true, false])
    func emptyReadRejectsAccountMismatchAndUnavailableMail(accountMismatch: Bool) async {
        let harness = OrganizationModelHarness()
        let analyzed = OrganizationAnalyzedCounts()
        let model = harness.makeModel(readSamples: { _, _, _ in
            .init(accountID: accountMismatch ? "other" : "a", messages: [], existingLabels: [],
                selectedCount: accountMismatch ? 0 : 1, unavailableCount: accountMismatch ? 0 : 1,
                isPartial: !accountMismatch)
        }, analyze: { samples, _, _ in
            await analyzed.record(samples.messages.count)
            return .init(categories: [], analyzedCount: 0)
        })
        model.startAnalysis()
        await model.waitForOperation()
        #expect(await analyzed.counts.isEmpty)
        #expect(model.phase == .idle && model.samples == nil && model.errorMessage != nil)
    }

    @Test func interruptedJobResumesCheckpointWithoutReadingMailAgain() async throws {
        let harness = OrganizationModelHarness()
        let job = OrganizationResumableJob()
        var limits: [Int] = []
        let model = harness.makeModel(readJobSamples: { _, maximum, _, _ in
            limits.append(maximum)
            return harness.samples
        }, analyzeJob: { _, _, checkpoint, _, progress, didCheckpoint in
            try await job.run(checkpoint: checkpoint, progress: progress, didCheckpoint: didCheckpoint)
        })
        model.scanMaximumMessages = 20_000
        model.startAnalysis()
        await model.waitForOperation()
        let startedAt = model.analysisStartedAt
        #expect(model.phase == .paused && model.canResumeAnalysis)
        #expect(model.samples == harness.samples)
        #expect(model.categories.isEmpty && !model.canApply)
        #expect(model.analysisProgress?.completedBatches == 1)
        #expect(limits == [20_000])
        model.resumeAnalysis()
        await model.waitForOperation()
        #expect(await job.checkpointsOnEntry == [false, true])
        #expect(limits == [20_000])
        #expect(model.analysisStartedAt == startedAt)
        #expect(model.phase == .review && !model.canResumeAnalysis)
        #expect(model.canApply)
    }

    @Test(arguments: [true, false])
    func canceledOrRevokedJobsRejectLateCheckpointsAndProgress(accessChanged: Bool) async throws {
        let harness = OrganizationModelHarness()
        let job = OrganizationResumableJob()
        let model = harness.makeModel(analyzeJob: { _, _, checkpoint, _, progress, didCheckpoint in
            try await job.run(checkpoint: checkpoint, progress: progress, didCheckpoint: didCheckpoint)
        })
        model.startAnalysis()
        await model.waitForOperation()
        #expect(model.canResumeAnalysis)
        if accessChanged {
            harness.access = harness.accessWithRevision(2)
            model.refreshAccess()
        } else { model.clear() }
        await job.publishLateCallbacks()
        #expect(model.phase == .idle && !model.canResumeAnalysis)
        #expect(model.analysisProgress == nil && model.samples == nil)
        model.startAnalysis()
        await model.waitForOperation()
        #expect(await job.checkpointsOnEntry == [false, false])
        #expect(model.phase == .review)
    }

    @Test func existingLabelBindingAndRuleCoverageSurviveReviewAndApply() async throws {
        let label = try JSONDecoder().decode(GmailLabel.self,
            from: Data(#"{"id":"Label_news","name":"Newsletters","type":"user"}"#.utf8))
        let filter = GmailFilter(id: "Filter_news", criteria: .init(from: "news@example.invalid"),
                                 action: .init(addLabelIds: [label.id]))
        let harness = OrganizationModelHarness(existingLabels: [label], existingFilters: [filter])
        let model = harness.makeModel(analyze: { _, _, _ in
            var categories = OrganizationModelHarness.plan.categories
            let news = categories[0]
            categories[0] = .init(id: news.id, name: news.name, explanation: news.explanation, kind: news.kind,
                messageIDs: news.messageIDs, ruleSenders: news.ruleSenders, existingLabelID: label.id)
            return .init(categories: categories, analyzedCount: 3)
        })
        model.startAnalysis()
        await model.waitForOperation()
        #expect(model.categories[0].existingLabelID == label.id)
        #expect(model.selectedExistingLabelCount == 1 && model.selectedNewLabelCount == 1)
        #expect(model.selectedFilterCount == 0 && model.selectedCoveredFilterCount == 1)
        model.categories[0].name = "Renamed label"
        #expect(!model.canApply)
        model.categories[0].name = label.name
        model.applySelection()
        await model.waitForOperation()
        #expect(harness.applied.first?.first?.existingLabelID == label.id)
    }

    @Test func cachedSessionsKeepAnalysisAndReviewEditsUntilExplicitlyCleared() async throws {
        let harness = OrganizationModelHarness()
        let reading = OrganizationSamplingGate(samples: harness.samples)
        var reads = 0
        let sessions = MailOrganizationSessions(accountIDs: { ["a", "b"] }, makeSession: { accountID in
            let model = accountID == "a" ? harness.makeModel(readSamples: { _, _, progress in
                reads += 1
                await progress(.init(stage: .reading, processedCount: 1, selectedCount: 3))
                return await reading.result()
            }) : OrganizationModelHarness().makeModel()
            return .init(connection: SettingsAccountState(accountID: accountID, store: nil), model: model)
        })
        var presented = try #require(sessions.session(for: "a"))
        presented.model.startAnalysis()
        await reading.waitUntilStarted()
        let startedAt = presented.model.analysisStartedAt
        sessions.selectedAccountID = "b"
        presented = try #require(sessions.session(for: "b"))
        #expect(presented.model.phase == .idle)
        sessions.selectedAccountID = "a"
        presented = try #require(sessions.session(for: sessions.selectedAccountID))
        #expect(presented.model.phase == .reading)
        #expect(presented.model.samplingProgress?.processedCount == 1)
        #expect(presented.model.analysisStartedAt == startedAt)
        presented.model.startAnalysis()
        #expect(reads == 1)
        await reading.release()
        await presented.model.waitForOperation()
        presented.model.categories[0].name = "Reading/News"
        presented.model.categories[0].selectedMessageIDs.remove("m2")
        presented.model.categories[1].isSelected = false

        let reopened = try #require(sessions.session(for: "a"))
        #expect(reopened === presented)
        #expect(sessions.selectedAccountID == "a")
        #expect(reopened.model.phase == .review)
        #expect(reopened.model.categories[0].name == "Reading/News")
        #expect(reopened.model.categories[0].selectedMessageIDs == ["m1"])
        #expect(!reopened.model.categories[1].isSelected)
        reopened.model.clear()
        let restarted = try #require(sessions.session(for: "a"))
        #expect(restarted.model.phase == .idle)
        #expect(restarted.model.samples == nil && restarted.model.categories.isEmpty)
    }

    @Test func hiddenReviewIsClearedWhenAccessChangesWithoutAView() async throws {
        let harness = OrganizationModelHarness()
        let model = harness.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        #expect(model.phase == .review)
        harness.access = harness.accessWithRevision(2)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while model.phase != .idle, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.phase == .idle)
        #expect(model.samples == nil && model.categories.isEmpty)
        #expect(!model.canApply)
    }

    @Test func removingAnAccountCancelsItsHiddenSessionAndRejectsLateResults() async throws {
        let harness = OrganizationModelHarness()
        let reading = OrganizationSamplingGate(samples: harness.samples)
        let accounts = OrganizationAccountIDs()
        let sessions = MailOrganizationSessions(accountIDs: { accounts.ids }, makeSession: { accountID in
            .init(connection: SettingsAccountState(accountID: accountID, store: nil),
                model: harness.makeModel(readSamples: { _, _, _ in await reading.result() }))
        })
        let session = try #require(sessions.session(for: "a"))
        session.model.startAnalysis()
        await reading.waitUntilStarted()
        let completion = Task { await session.model.waitForOperation() }
        await Task.yield()
        accounts.ids = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while session.model.phase != .idle, ContinuousClock.now < deadline { await Task.yield() }
        #expect(session.model.phase == .idle)
        #expect(sessions.selectedAccountID.isEmpty)
        #expect(sessions.session(for: "a") == nil)
        await reading.release()
        await completion.value
        #expect(session.model.samples == nil && session.model.categories.isEmpty)
    }

    @Test func reviewAppliesOnlySelectedEditedCategoriesAndWaitsForDelivery() async throws {
        let harness = OrganizationModelHarness()
        let model = harness.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        #expect(model.phase == .review)
        #expect(harness.applied.isEmpty)
        #expect(model.categories[0].createsFilter)
        #expect(!model.categories[1].createsFilter)
        model.categories[0].name = "Reading/News"
        model.categories[0].createsFilter = false
        model.categories[1].isSelected = false
        model.applySelection()
        await model.waitForOperation()
        let applied = try #require(harness.applied.first)
        #expect(harness.applied.count == 1)
        #expect(applied.map(\.name) == ["Reading/News"])
        #expect(applied.flatMap(\.messageIDs) == ["m1", "m2"])
        #expect(applied.allSatisfy { !$0.createFilter })
        #expect(model.phase == .queued)
        #expect(!model.canApply)
        model.applySelection()
        #expect(harness.applied.count == 1)

        harness.delivery = .init(pendingCount: 0, sentCount: 1, failedCount: 0, unconfirmedCount: 1)
        await model.refreshDelivery()
        #expect(model.phase == .queued)
        harness.delivery = .init(pendingCount: 0, sentCount: 1, failedCount: 1, unconfirmedCount: 0)
        await model.refreshDelivery()
        #expect(model.phase == .queued)
        harness.delivery = .init(pendingCount: 0, sentCount: 2, failedCount: 0, unconfirmedCount: 0)
        await model.refreshDelivery()
        #expect(model.phase == .complete)
        model.clear()
        #expect(model.samples == nil && model.categories.isEmpty && model.receipt == nil)
        #expect(model.samplingProgress == nil && model.analysisStartedAt == nil)
    }

    @Test func removingOneExamplePreventsItsSenderRuleAndAppliesOnlyIncludedMessages() async throws {
        let harness = OrganizationModelHarness()
        let model = harness.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        #expect(model.categories[0].createsFilter)
        model.categories[0].selectedMessageIDs.remove("m2")
        #expect(!model.categories[0].createsFilter)
        #expect(model.selectedMessageCount == 2)
        #expect(model.selectedFilterCount == 0)
        model.categories[0].createsFilter = true
        #expect(!model.canApply)
        model.categories[0].createsFilter = false
        model.applySelection()
        await model.waitForOperation()
        let applied = try #require(harness.applied.first)
        #expect(applied.flatMap(\.messageIDs) == ["m1", "m3"])
        #expect(applied.flatMap(\.ruleSenders).isEmpty)
        #expect(applied.allSatisfy { !$0.createFilter })
    }

    @Test func excludedMessagesMustBeRestoredBeforeReenablingFutureFilters() async throws {
        let harness = OrganizationModelHarness()
        let model = harness.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        model.categories[0].selectedMessageIDs = []
        #expect(!model.canApply)
        model.categories[0].selectedMessageIDs = ["m1", "m2", "invented"]
        #expect(!model.canApply)
        model.categories[0].selectedMessageIDs = ["m1", "m2"]
        #expect(!model.categories[0].createsFilter)
        model.categories[0].createsFilter = true
        #expect(model.canApply)
        #expect(model.selectedFilterCount == 1)
        model.applySelection()
        await model.waitForOperation()
        #expect(harness.applied.first?.first?.ruleSenders == ["news@example.invalid"])
    }

    @Test(arguments: [true, false])
    func partialSamplesAndMissingSettingsPermissionAllowLabelsOnly(partial: Bool) async throws {
        let harness = OrganizationModelHarness(partial: partial, canCreateFilters: partial)
        let model = harness.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        #expect(model.categories.allSatisfy { !$0.createsFilter })
        model.setAllSuggestionsSelected(false)
        model.setAllSuggestionsSelected(true)
        #expect(model.categories.allSatisfy { !$0.createsFilter })
        #expect(model.canApply)
        model.categories[0].createsFilter = true
        #expect(!model.canApply)
        model.categories[0].createsFilter = false
        model.categories[0].name = "INBOX"
        #expect(!model.canApply)
        model.categories[0].name = model.categories[1].name
        #expect(!model.canApply)
        model.categories[1].isSelected = false
        #expect(!model.canApply)
        model.categories[1].isSelected = true
        model.categories[0].name = "Newsletters"
        model.applySelection()
        await model.waitForOperation()
        #expect(harness.applied.first?.allSatisfy { !$0.createFilter } == true)
    }

    @Test func permissionEpochRejectsLateAnalysisAfterRevokeAndRegrant() async throws {
        let harness = OrganizationModelHarness()
        let gate = OrganizationAnalysisGate()
        let model = harness.makeModel(analyze: { _, _, isAuthorized in
            let result = await gate.result()
            #expect(await isAuthorized() == false)
            return result
        })
        model.startAnalysis()
        await gate.waitUntilStarted()
        // Keep a waiter on the original operation before access clears its handle.
        let completion = Task { await model.waitForOperation() }
        await Task.yield()
        harness.access = harness.accessWithRevision(2)
        model.refreshAccess()
        await gate.release()
        await completion.value
        #expect(model.phase == .idle)
        #expect(model.samples == nil && model.categories.isEmpty)
        #expect(model.samplingProgress == nil && model.analysisStartedAt == nil)
        #expect(!model.canApply)
        #expect(harness.applied.isEmpty)
    }

    @Test func changedAccountOrPermissionCannotApplyAnEarlierReview() async throws {
        let harness = OrganizationModelHarness()
        let model = harness.makeModel()
        model.startAnalysis()
        await model.waitForOperation()
        harness.access = harness.accessWithRevision(1, instance: "replacement")
        #expect(!model.canApply)
        model.applySelection()
        #expect(harness.applied.isEmpty)
        model.refreshAccess()
        #expect(model.samples == nil && model.categories.isEmpty)
    }

    @Test func progressFollowsTheCurrentReadAndIgnoresLateCallbacks() async throws {
        let harness = OrganizationModelHarness()
        let reading = OrganizationSamplingGate(samples: harness.samples)
        let analyzing = OrganizationAnalysisGate()
        var reports: [MailOrganizationModel.Progress] = []
        let model = harness.makeModel(readSamples: { _, _, progress in
            reports.append(progress)
            await progress(.init(stage: .reading, processedCount: reports.count == 1 ? 1 : 3, selectedCount: 3))
            if reports.count == 1 { return await reading.result() }
            return harness.samples
        }, analyze: { _, _, _ in await analyzing.result() })

        model.startAnalysis()
        await reading.waitUntilStarted()
        #expect(model.phase == .reading)
        #expect(model.samplingProgress == .init(stage: .reading, processedCount: 1, selectedCount: 3))
        #expect(model.analysisStartedAt != nil)
        let cancelled = Task { await model.waitForOperation() }
        await Task.yield()
        model.clear()
        await reports[0](.init(stage: .reading, processedCount: 2, selectedCount: 3))
        #expect(model.samplingProgress == nil && model.analysisStartedAt == nil)
        await reading.release()
        await cancelled.value

        model.startAnalysis()
        let analysisStarted = try #require(model.analysisStartedAt)
        await analyzing.waitUntilStarted()
        #expect(model.phase == .analyzing)
        let finalRead = try #require(model.samplingProgress)
        #expect(finalRead.processedCount == 3)
        #expect(model.analysisStartedAt == analysisStarted)
        await reports[0](.init(stage: .reading, processedCount: 2, selectedCount: 3))
        await reports[1](.init(stage: .reading, processedCount: 2, selectedCount: 3))
        #expect(model.samplingProgress == finalRead)
        #expect(model.analysisStartedAt == analysisStarted)
        await analyzing.release()
        await model.waitForOperation()
        #expect(model.phase == .review)
    }

    @Test func failedReadClearsProgressAndTimestamps() async {
        let harness = OrganizationModelHarness()
        let model = harness.makeModel(readSamples: { _, _, progress in
            await progress(.init(stage: .listing, selectedCount: 20))
            throw AIProviderError.network
        })
        model.startAnalysis()
        await model.waitForOperation()
        #expect(model.phase == .idle)
        #expect(model.errorMessage != nil)
        #expect(model.samplingProgress == nil && model.analysisStartedAt == nil)
    }

    @Test func revokedAccessDuringTokenRefreshStopsMetadataBeforeTransport() async throws {
        let harness = OrganizationModelHarness()
        let gate = OrganizationTokenGate()
        let provider = MailOrganizationBindings.scopedProvider(accessToken: { await gate.token() },
            isAuthorized: { await MainActor.run { harness.access.permissionRevision == 1 } },
            transport: AIHTTPTransport { _ in
                await gate.recordSend()
                throw AIProviderError.network
            })
        let request = AIRequest(model: "test", input: [.object(["role": .string("user"), "content": .string("private sample")])],
                                instructions: "Test request", tools: [])
        let pending = Task {
            do { for try await _ in provider.respond(request) {} }
            catch { return }
            Issue.record("A revoked request unexpectedly completed.")
        }
        await gate.waitUntilStarted()
        // Deliberately omit refreshAccess/cancellation to exercise the network gate.
        harness.access = harness.accessWithRevision(2)
        await gate.release()
        await pending.value
        #expect(await gate.sends == 0)
    }
}

@MainActor @Observable private final class OrganizationAccountIDs {
    var ids = ["a"]
}

@MainActor @Observable private final class OrganizationModelHarness {
    var access: MailOrganizationAccess
    let samples: MailOrganizationSamples
    var applied: [[OrganizationApplicationCategory]] = []
    var delivery = OrganizationApplicationStatus(pendingCount: 2, sentCount: 0, failedCount: 0, unconfirmedCount: 0)

    init(partial: Bool = false, canCreateFilters: Bool = true, messageCount: Int = 3,
         existingLabels: [GmailLabel] = [], existingFilters: [GmailFilter] = []) {
        access = .init(accountID: "a", instanceID: "a-instance", permissionRevision: 1, connectionRevision: 1,
            modelID: "test", mailAccessEnabled: true, canCreateFilters: canCreateFilters)
        samples = .init(accountID: "a", messages: (0..<messageCount).map {
            let index = $0 + 1
            return .init(messageID: "m\(index)", threadID: "t\(index)", sender: index == 3 ? "colleague@example.invalid" : "news@example.invalid",
                recipients: ["reader@example.invalid"], subject: "Example \(index)", snippet: "Sample preview",
                date: Date(timeIntervalSince1970: TimeInterval(index)), isSent: false, labelIDs: [], hasMailingListHeaders: index != 3)
        }, existingLabels: existingLabels, selectedCount: messageCount + (partial ? 1 : 0), unavailableCount: partial ? 1 : 0,
            isPartial: partial, existingFilters: existingFilters, filterContextAvailable: true)
    }

    func makeModel(readSamples: MailOrganizationModel.ReadSamples? = nil,
                   analyze: MailOrganizationModel.Analyze? = nil,
                   readJobSamples: MailOrganizationModel.ReadJobSamples? = nil,
                   analyzeJob: MailOrganizationModel.AnalyzeJob? = nil) -> MailOrganizationModel {
        MailOrganizationModel(access: { self.access }, readSamples: readSamples ?? { _, isAuthorized, _ in
            guard await isAuthorized() else { throw CancellationError() }
            return self.samples
        }, analyze: analyze ?? { _, _, _ in Self.plan }, apply: { categories, samples, isAuthorized in
            guard await isAuthorized() else { throw CancellationError() }
            #expect(samples.accountID == "a")
            self.applied.append(categories)
            return OrganizationApplicationReceipt(accountID: "a", actionIDs: [1, 2], categoryCount: categories.count,
                messageCount: Set(categories.filter(\.backfillExisting).flatMap(\.messageIDs)).count,
                filterCount: categories.filter(\.createFilter).flatMap(\.ruleSenders).count,
                actions: ActionReceipt(actions: []))
        }, status: { _ in self.delivery }, readJobSamples: readJobSamples, analyzeJob: analyzeJob)
    }

    func accessWithRevision(_ revision: Int, instance: String = "a-instance") -> MailOrganizationAccess {
        .init(accountID: "a", instanceID: instance, permissionRevision: revision, connectionRevision: 1,
            modelID: "test", mailAccessEnabled: true, canCreateFilters: access.canCreateFilters)
    }

    nonisolated static var plan: OrganizationPlan {
        .init(categories: [
            .init(id: "news", name: "Newsletters", explanation: "Regular updates from a publisher.", kind: .topic,
                messageIDs: ["m1", "m2"], ruleSenders: ["news@example.invalid"]),
            .init(id: "action", name: "Action", explanation: "An incoming request needs a response.", kind: .action,
                messageIDs: ["m3"], ruleSenders: []),
        ], analyzedCount: 3)
    }
}

private actor OrganizationAnalyzedCounts {
    private(set) var counts: [Int] = []
    func record(_ count: Int) { counts.append(count) }
}

private actor OrganizationResumableJob {
    private(set) var checkpointsOnEntry: [Bool] = []
    private var progress: MailOrganizationModel.AnalysisProgress?
    private var didCheckpoint: MailOrganizationModel.Checkpoint?

    func run(checkpoint: OrganizationAnalysisCheckpoint?, progress: @escaping MailOrganizationModel.AnalysisProgress,
             didCheckpoint: @escaping MailOrganizationModel.Checkpoint) async throws -> OrganizationPlan {
        checkpointsOnEntry.append(checkpoint != nil)
        self.progress = progress
        self.didCheckpoint = didCheckpoint
        await progress(.init(stage: .discovering, completedBatches: 1, totalBatches: 2, analyzedCount: 3))
        await didCheckpoint(.init())
        if checkpointsOnEntry.count == 1 { throw AIProviderError.network }
        return OrganizationModelHarness.plan
    }

    func publishLateCallbacks() async {
        await progress?(.init(stage: .auditing, completedBatches: 2, totalBatches: 2, analyzedCount: 3))
        await didCheckpoint?(.init())
    }
}

private actor OrganizationSamplingGate {
    let samples: MailOrganizationSamples
    private var continuation: CheckedContinuation<MailOrganizationSamples, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(samples: MailOrganizationSamples) { self.samples = samples }

    func result() async -> MailOrganizationSamples {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { continuation?.resume(returning: samples); continuation = nil }
}

private actor OrganizationAnalysisGate {
    private var continuation: CheckedContinuation<OrganizationPlan, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func result() async -> OrganizationPlan {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        continuation?.resume(returning: OrganizationModelHarness.plan)
        continuation = nil
    }
}

private actor OrganizationTokenGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var sends = 0

    func token() async -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { continuation?.resume(returning: "test-token"); continuation = nil }
    func recordSend() { sends += 1 }
}
