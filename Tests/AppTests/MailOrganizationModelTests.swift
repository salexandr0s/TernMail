import Foundation
import Testing
import TernAI
@testable import SyncEngine
@testable import Tern

@Suite @MainActor struct MailOrganizationModelTests {
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

@MainActor private final class OrganizationModelHarness {
    var access: MailOrganizationAccess
    let samples: MailOrganizationSamples
    var applied: [[OrganizationApplicationCategory]] = []
    var delivery = OrganizationApplicationStatus(pendingCount: 2, sentCount: 0, failedCount: 0, unconfirmedCount: 0)

    init(partial: Bool = false, canCreateFilters: Bool = true) {
        access = .init(accountID: "a", instanceID: "a-instance", permissionRevision: 1, connectionRevision: 1,
            modelID: "test", mailAccessEnabled: true, canCreateFilters: canCreateFilters)
        samples = .init(accountID: "a", messages: (1...3).map {
            .init(messageID: "m\($0)", threadID: "t\($0)", sender: $0 == 3 ? "colleague@example.invalid" : "news@example.invalid",
                recipients: ["reader@example.invalid"], subject: "Example \($0)", snippet: "Sample preview",
                date: Date(timeIntervalSince1970: TimeInterval($0)), isSent: false, labelIDs: [], hasMailingListHeaders: $0 != 3)
        }, existingLabels: [], selectedCount: partial ? 4 : 3, unavailableCount: partial ? 1 : 0, isPartial: partial)
    }

    func makeModel(readSamples: MailOrganizationModel.ReadSamples? = nil,
                   analyze: MailOrganizationModel.Analyze? = nil) -> MailOrganizationModel {
        MailOrganizationModel(access: { self.access }, readSamples: readSamples ?? { _, isAuthorized, _ in
            guard await isAuthorized() else { throw CancellationError() }
            return self.samples
        }, analyze: analyze ?? { _, _, _ in Self.plan }, apply: { categories, samples, isAuthorized in
            guard await isAuthorized() else { throw CancellationError() }
            #expect(samples.accountID == "a")
            self.applied.append(categories)
            return OrganizationApplicationReceipt(accountID: "a", actionIDs: [1, 2], categoryCount: categories.count,
                messageCount: Set(categories.flatMap(\.messageIDs)).count,
                filterCount: categories.filter(\.createFilter).flatMap(\.ruleSenders).count,
                actions: ActionReceipt(actions: []))
        }, status: { _ in self.delivery })
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
