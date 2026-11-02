import Foundation
import MailStore
import Observation
import SyncEngine
import TernAI

struct MailOrganizationAccess: Equatable, Sendable {
    let accountID: String
    let instanceID: String?
    let permissionRevision: Int
    let connectionRevision: Int
    let modelID: String?
    let mailAccessEnabled: Bool
    let canCreateFilters: Bool

    var canAnalyze: Bool { instanceID != nil && mailAccessEnabled && modelID != nil }
}

struct MailOrganizationReviewCategory: Identifiable {
    let proposal: OrganizationCategory
    var name: String
    var isSelected = true
    var createsFilter: Bool
    var id: String { proposal.id }

    init(_ proposal: OrganizationCategory, canCreateFilters: Bool) {
        self.proposal = proposal
        name = proposal.name
        createsFilter = canCreateFilters && proposal.kind == .topic && !proposal.ruleSenders.isEmpty
    }
}

@MainActor @Observable
final class MailOrganizationModel {
    enum Phase { case idle, reading, analyzing, review, applying, queued, complete }
    typealias Authorized = @Sendable () async -> Bool
    typealias Progress = @Sendable (MailOrganizationSamplingProgress) async -> Void
    typealias ReadSamples = @MainActor (MailOrganizationAccess, @escaping Authorized, @escaping Progress) async throws -> MailOrganizationSamples
    typealias Analyze = @Sendable (MailOrganizationSamples, String, @escaping Authorized) async throws -> OrganizationPlan
    typealias Apply = @MainActor ([OrganizationApplicationCategory], MailOrganizationSamples, @escaping Authorized) async throws -> OrganizationApplicationReceipt

    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { phaseStartedAt = phase == .idle ? nil : Date() }
        }
    }
    private(set) var samplingProgress: MailOrganizationSamplingProgress?
    private(set) var analysisStartedAt: Date?
    private(set) var phaseStartedAt: Date?
    private(set) var samples: MailOrganizationSamples?
    private(set) var errorMessage: String?
    private(set) var delivery: OrganizationApplicationStatus?
    private(set) var receipt: OrganizationApplicationReceipt?
    var categories: [MailOrganizationReviewCategory] = []
    @ObservationIgnored private let access: @MainActor () -> MailOrganizationAccess
    @ObservationIgnored private let readSamples: ReadSamples
    @ObservationIgnored private let analyze: Analyze
    @ObservationIgnored private let apply: Apply
    @ObservationIgnored private let status: @MainActor (OrganizationApplicationReceipt) async throws -> OrganizationApplicationStatus
    @ObservationIgnored private var snapshot: MailOrganizationAccess?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(access: @escaping @MainActor () -> MailOrganizationAccess, readSamples: @escaping ReadSamples,
         analyze: @escaping Analyze, apply: @escaping Apply,
         status: @escaping @MainActor (OrganizationApplicationReceipt) async throws -> OrganizationApplicationStatus) {
        self.access = access; self.readSamples = readSamples; self.analyze = analyze
        self.apply = apply; self.status = status
    }

    var isAnalyzing: Bool { phase == .reading || phase == .analyzing }
    var isBusy: Bool { isAnalyzing || phase == .applying }
    var canAnalyze: Bool { access().canAnalyze && !isBusy && phase != .queued }
    var selectedCount: Int { categories.filter(\.isSelected).count }
    var selectedMessageCount: Int { Set(categories.filter(\.isSelected).flatMap { $0.proposal.messageIDs }).count }
    var selectedFilterCount: Int { categories.filter { $0.isSelected && $0.createsFilter }.reduce(0) { $0 + $1.proposal.ruleSenders.count } }
    var canApply: Bool { phase == .review && snapshot == access() && validationMessage == nil }

    var validationMessage: String? {
        let selected = categories.filter(\.isSelected)
        guard !selected.isEmpty else { return "Select at least one category to apply." }
        var names = Set<String>()
        for category in selected {
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MailOrganizationAnalyzer.validLabelName(name),
                  LabelRules.problem(with: name, among: []) == nil else {
                return "Choose a shorter label name with no empty parts or reserved Gmail names."
            }
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard (key != "action" || category.proposal.kind == .action),
                  (key != "waiting" || category.proposal.kind == .waiting) else {
                return "Use Action and Waiting for their matching review categories."
            }
            guard names.insert(key).inserted else {
                return "Each selected category needs a different label name."
            }
            if category.createsFilter && !access().canCreateFilters {
                return "Turn on Gmail Settings in Connections to create future filters, or turn off the filter switches."
            }
            if category.createsFilter && samples?.isPartial == true {
                return "Analyze a complete sample before creating filters for future mail."
            }
        }
        return nil
    }

    func startAnalysis() {
        guard canAnalyze else { return }
        clear()
        let expected = access()
        snapshot = expected
        let job = generation
        analysisStartedAt = Date()
        phase = .reading
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await readSamples(expected, authorization(job, expected), progress(job, expected))
                try check(job, expected)
                guard loaded.accountID == expected.accountID, !loaded.messages.isEmpty else {
                    errorMessage = "No recent messages were available to analyze. Try again after Gmail finishes syncing."
                    phase = .idle
                    samplingProgress = nil; analysisStartedAt = nil
                    return
                }
                samples = loaded
                phase = .analyzing
                guard let modelID = expected.modelID else { throw CancellationError() }
                let plan = try await analyze(loaded, modelID, authorization(job, expected))
                try check(job, expected)
                let ids = Set(loaded.messages.map(\.messageID))
                guard plan.analyzedCount <= ids.count,
                      plan.categories.allSatisfy({ Set($0.messageIDs).isSubset(of: ids) }) else {
                    throw AssistantMailError.accessChanged
                }
                categories = plan.categories.map { .init($0, canCreateFilters: expected.canCreateFilters && !loaded.isPartial) }
                phase = .review
            } catch {
                guard acceptsFailure(job, expected) else { return }
                samples = nil; categories = []; phase = .idle
                samplingProgress = nil; analysisStartedAt = nil
                errorMessage = (error as? MailOrganizationError)?.localizedDescription
                    ?? "Couldn't analyze these messages. Check the Google and ChatGPT connections, then try again."
            }
        }
    }

    func applySelection() {
        guard canApply, let samples, let expected = snapshot else { return }
        let job = generation
        let selected = categories.filter(\.isSelected).map { category in
            OrganizationApplicationCategory(id: category.id,
                name: category.name.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: Self.applicationKind(category.proposal.kind), messageIDs: category.proposal.messageIDs,
                ruleSenders: category.proposal.ruleSenders,
                createFilter: category.createsFilter && category.proposal.kind == .topic)
        }
        phase = .applying; errorMessage = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let queued = try await apply(selected, samples, authorization(job, expected))
                try check(job, expected)
                guard queued.accountID == expected.accountID else { throw AssistantMailError.accessChanged }
                receipt = queued; phase = .queued
                await refreshDelivery()
            } catch {
                guard acceptsFailure(job, expected) else { return }
                phase = .review
                errorMessage = Self.applicationMessage(error)
            }
        }
    }

    func refreshDelivery() async {
        guard let receipt, let expected = snapshot, snapshot == access() else { return }
        let job = generation
        do {
            let updated = try await status(receipt)
            try check(job, expected)
            delivery = updated
            errorMessage = nil
            phase = updated.isComplete ? .complete : .queued
        } catch {
            guard acceptsFailure(job, expected) else { return }
            errorMessage = "Couldn't check Gmail delivery. The saved changes remain in the queue."
        }
    }

    func watchDelivery() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if phase == .queued { await refreshDelivery() }
        }
    }

    func refreshAccess() {
        guard let snapshot, snapshot != access() else { return }
        clear()
        errorMessage = "Access or the selected model changed. Analyze again to prepare a new review."
    }

    /// Samples and proposals exist only while this pane owns the review.
    func clear() {
        generation = UUID(); operation?.cancel(); operation = nil
        samples = nil; categories = []; receipt = nil; delivery = nil
        samplingProgress = nil; analysisStartedAt = nil; phaseStartedAt = nil
        snapshot = nil; errorMessage = nil; phase = .idle
    }

    func waitForOperation() async { await operation?.value }

    private func authorization(_ job: UUID, _ expected: MailOrganizationAccess) -> Authorized {
        { [weak self] in await MainActor.run { self?.isCurrent(job, expected) == true } }
    }

    private func progress(_ job: UUID, _ expected: MailOrganizationAccess) -> Progress {
        { [weak self] value in
            await MainActor.run {
                guard let self, self.generation == job else { return }
                self.refreshAccess()
                guard self.isCurrent(job, expected), self.phase == .reading else { return }
                self.samplingProgress = value
            }
        }
    }

    private func isCurrent(_ job: UUID, _ expected: MailOrganizationAccess) -> Bool {
        generation == job && snapshot == expected && access() == expected && expected.canAnalyze
    }

    private func check(_ job: UUID, _ expected: MailOrganizationAccess) throws {
        try Task.checkCancellation()
        guard isCurrent(job, expected) else {
            if generation == job { refreshAccess() }
            throw CancellationError()
        }
    }

    private func acceptsFailure(_ job: UUID, _ expected: MailOrganizationAccess) -> Bool {
        if generation == job { refreshAccess() }
        return isCurrent(job, expected)
    }

    private static func applicationKind(_ kind: OrganizationCategory.Kind) -> OrganizationApplicationCategory.Kind {
        switch kind {
        case .topic: .topic
        case .action: .action
        case .waiting: .waiting
        }
    }

    private static func applicationMessage(_ error: any Error) -> String {
        guard let error = error as? OrganizationApplicationError else {
            return "Couldn't queue these changes. Check your Google connection and try again."
        }
        switch error {
        case .staleSamples, .accountMismatch:
            return "The sampled messages changed. Analyze again before applying labels."
        case .unsafeRule:
            return "These senders no longer support a future filter. Turn off the filter switches or analyze again."
        case .settingsPermissionRequired:
            return "Turn on Gmail Settings in Connections, or turn off the future filter switches."
        case .conflictingChange:
            return "Another label change is still pending. Let it finish, then try again."
        case .invalidSelection:
            return "Check the selected label names, or analyze again to prepare a new review."
        }
    }
}
