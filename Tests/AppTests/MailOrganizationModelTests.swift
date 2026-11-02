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
                date: Date(timeIntervalSince1970: TimeInterval($0)), isSent: false, labelIDs: [])
        }, existingLabels: [], selectedCount: partial ? 4 : 3, unavailableCount: partial ? 1 : 0, isPartial: partial)
    }

    func makeModel(analyze: MailOrganizationModel.Analyze? = nil) -> MailOrganizationModel {
        MailOrganizationModel(access: { self.access }, readSamples: { _, isAuthorized in
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
