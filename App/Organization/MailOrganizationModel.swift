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
    var backfillExisting = true
    var selectedMessageIDs: Set<String> {
        didSet {
            if selectedMessageIDs != oldValue { createsFilter = false }
        }
    }
    var id: String { proposal.id }
    var existingLabelID: String? { proposal.existingLabelID }

    init(_ proposal: OrganizationCategory, canCreateFilters: Bool) {
        self.proposal = proposal
        name = proposal.name
        selectedMessageIDs = Set(proposal.messageIDs)
        createsFilter = canCreateFilters && proposal.kind == .topic && !proposal.ruleSenders.isEmpty
    }

    mutating func setFutureMail(_ enabled: Bool) {
        if !isSelected { backfillExisting = false }
        createsFilter = enabled
        isSelected = createsFilter || backfillExisting
    }

    mutating func setBackfill(_ enabled: Bool) {
        if !isSelected { createsFilter = false }
        backfillExisting = enabled
        isSelected = createsFilter || backfillExisting
    }
}

@MainActor @Observable
final class MailOrganizationModel {
    enum Phase { case idle, reading, analyzing, paused, review, applying, queued, complete }
    typealias Authorized = @Sendable () async -> Bool
    typealias Progress = @Sendable (MailOrganizationSamplingProgress) async -> Void
    typealias ReadSamples = @MainActor (MailOrganizationAccess, @escaping Authorized, @escaping Progress) async throws -> MailOrganizationSamples
    typealias Analyze = @Sendable (MailOrganizationSamples, String, @escaping Authorized) async throws -> OrganizationPlan
    typealias ReadJobSamples = @MainActor (MailOrganizationAccess, Int, @escaping Authorized, @escaping Progress) async throws -> MailOrganizationSamples
    typealias AnalysisProgress = @Sendable (OrganizationAnalysisProgress) async -> Void
    typealias Checkpoint = @Sendable (OrganizationAnalysisCheckpoint) async -> Void
    typealias AnalyzeJob = @Sendable (MailOrganizationSamples, String, OrganizationAnalysisCheckpoint?, @escaping Authorized,
                                     @escaping AnalysisProgress, @escaping Checkpoint) async throws -> OrganizationPlan
    typealias Apply = @MainActor ([OrganizationApplicationCategory], MailOrganizationSamples, @escaping Authorized) async throws -> OrganizationApplicationReceipt

    private(set) var phase: Phase = .idle
    private(set) var samplingProgress: MailOrganizationSamplingProgress?
    private(set) var analysisProgress: OrganizationAnalysisProgress?
    private(set) var analysisStartedAt: Date?
    private(set) var samples: MailOrganizationSamples?
    private(set) var errorMessage: String?
    private(set) var delivery: OrganizationApplicationStatus?
    private(set) var receipt: OrganizationApplicationReceipt?
    var categories: [MailOrganizationReviewCategory] = []
    var scanMaximumMessages = 5_000
    @ObservationIgnored private let access: @MainActor () -> MailOrganizationAccess
    @ObservationIgnored private let readSamples: ReadSamples
    @ObservationIgnored private let analyze: Analyze
    @ObservationIgnored private let readJobSamples: ReadJobSamples?
    @ObservationIgnored private let analyzeJob: AnalyzeJob?
    @ObservationIgnored private var checkpoint: OrganizationAnalysisCheckpoint?
    @ObservationIgnored private let apply: Apply
    @ObservationIgnored private let status: @MainActor (OrganizationApplicationReceipt) async throws -> OrganizationApplicationStatus
    @ObservationIgnored private var snapshot: MailOrganizationAccess?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(access: @escaping @MainActor () -> MailOrganizationAccess, readSamples: @escaping ReadSamples,
         analyze: @escaping Analyze, apply: @escaping Apply,
         status: @escaping @MainActor (OrganizationApplicationReceipt) async throws -> OrganizationApplicationStatus,
         readJobSamples: ReadJobSamples? = nil, analyzeJob: AnalyzeJob? = nil) {
        self.access = access; self.readSamples = readSamples; self.analyze = analyze
        self.apply = apply; self.status = status
        self.readJobSamples = readJobSamples; self.analyzeJob = analyzeJob
        observeAccess()
    }

    var isAnalyzing: Bool { phase == .reading || phase == .analyzing }
    var isBusy: Bool { isAnalyzing || phase == .applying }
    var canAnalyze: Bool { access().canAnalyze && !isBusy && phase != .queued }
    var canResumeAnalysis: Bool { phase == .paused && samples != nil && analyzeJob != nil && snapshot == access() }
    var isAnalysisPaused: Bool { phase == .paused }
    var selectedCount: Int { categories.filter(\.isSelected).count }
    var selectedMessageCount: Int {
        Set(categories.filter { $0.isSelected && $0.backfillExisting }.flatMap(\.selectedMessageIDs)).count
    }
    var selectedExistingLabelCount: Int { categories.filter { $0.isSelected && existingLabelID(for: $0) != nil }.count }
    var selectedNewLabelCount: Int { selectedCount - selectedExistingLabelCount }
    var selectedFilterCount: Int {
        categories.filter { $0.isSelected && $0.createsFilter }.reduce(0) {
            $0 + (ruleCoverage(for: $1)?.newFilterCount ?? 0)
        }
    }
    var selectedRuleSuggestionCount: Int {
        categories.filter { $0.isSelected && $0.createsFilter && (ruleCoverage(for: $0)?.newFilterCount ?? 0) > 0 }.count
    }
    var selectedCoveredFilterCount: Int {
        categories.filter(\.isSelected).reduce(0) {
            $0 + (ruleCoverage(for: $1)?.alreadyCoveredSenders.count ?? 0)
        }
    }
    var canApply: Bool { phase == .review && snapshot == access() && validationMessage == nil }

    var validationMessage: String? {
        let selected = categories.filter(\.isSelected)
        guard !selected.isEmpty else { return "Select at least one category to apply." }
        var names = Set<String>()
        for category in selected {
            guard category.backfillExisting || (category.createsFilter && (ruleCoverage(for: category)?.newFilterCount ?? 0) > 0) else {
                return "Choose a new future rule or label the scanned mail for each selected suggestion."
            }
            guard !category.selectedMessageIDs.isEmpty,
                  category.selectedMessageIDs.isSubset(of: Set(category.proposal.messageIDs)) else {
                return "Include at least one suggested message in each selected label."
            }
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let labelID = category.existingLabelID {
                guard let label = samples?.existingLabels.first(where: { $0.id == labelID && !$0.isSystem }),
                      label.name == name else {
                    return "Existing labels keep their current names. Start a new analysis if a label changed."
                }
            }
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
            if category.createsFilter && eligibleRuleSenders(for: category).isEmpty {
                return "The selected messages no longer support a future sender filter. Turn off future mail for this label."
            }
        }
        return nil
    }

    func startAnalysis() {
        guard canAnalyze else { return }
        clear()
        let expected = access()
        snapshot = expected
        analysisStartedAt = Date()
        runAnalysis(expected)
    }

    func setAllSuggestionsSelected(_ selected: Bool) {
        let canCreateFilters = access().canCreateFilters && samples?.isPartial == false
        for index in categories.indices {
            if selected {
                categories[index].setBackfill(true)
                let makesNewRule = canCreateFilters && (ruleCoverage(for: categories[index])?.newFilterCount ?? 0) > 0
                categories[index].setFutureMail(makesNewRule)
            } else {
                categories[index].setFutureMail(false)
                categories[index].setBackfill(false)
            }
        }
    }

    func resumeAnalysis() {
        guard canResumeAnalysis, let expected = snapshot else { return }
        generation = UUID()
        operation?.cancel()
        errorMessage = nil
        runAnalysis(expected)
    }

    private func runAnalysis(_ expected: MailOrganizationAccess) {
        let job = generation
        let maximumMessages = scanMaximumMessages
        phase = samples == nil ? .reading : .analyzing
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded: MailOrganizationSamples
                if let samples {
                    loaded = samples
                } else if let readJobSamples {
                    loaded = try await readJobSamples(expected, maximumMessages, authorization(job, expected), progress(job, expected))
                } else {
                    loaded = try await readSamples(expected, authorization(job, expected), progress(job, expected))
                }
                try check(job, expected)
                guard loaded.accountID == expected.accountID else { throw AssistantMailError.accessChanged }
                if loaded.messages.isEmpty {
                    if loaded.selectedCount == 0, loaded.unavailableCount == 0, !loaded.isPartial {
                        samples = loaded
                        categories = []
                        phase = .review
                        samplingProgress = nil; analysisStartedAt = nil
                        return
                    }
                    errorMessage = "No recent messages were available to analyze. Try again after Gmail finishes syncing."
                    phase = .idle
                    samplingProgress = nil; analysisStartedAt = nil
                    return
                }
                samples = loaded
                phase = .analyzing
                guard let modelID = expected.modelID else { throw CancellationError() }
                let plan: OrganizationPlan
                if let analyzeJob {
                    plan = try await analyzeJob(loaded, modelID, checkpoint, authorization(job, expected),
                        analysisProgressCallback(job, expected), checkpointCallback(job, expected))
                } else {
                    plan = try await analyze(loaded, modelID, authorization(job, expected))
                }
                try check(job, expected)
                let ids = Set(loaded.messages.map(\.messageID))
                guard plan.analyzedCount <= ids.count,
                      plan.categories.allSatisfy({ Set($0.messageIDs).isSubset(of: ids) }) else {
                    throw AssistantMailError.accessChanged
                }
                categories = plan.categories.map { proposal in
                    let eligible = loaded.eligibleRuleSenders(proposal.ruleSenders, selectedMessageIDs: Set(proposal.messageIDs))
                    let coverage = loaded.ruleCoverage(existingLabelID: proposal.existingLabelID, labelName: proposal.name,
                                                       proposedSenders: eligible)
                    return .init(proposal, canCreateFilters: expected.canCreateFilters && coverage.newFilterCount > 0)
                }
                phase = .review
            } catch {
                guard acceptsFailure(job, expected) else { return }
                categories = []
                if analyzeJob != nil, samples != nil {
                    phase = .paused
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "The analysis stopped. Resume to continue from the last completed step."
                } else {
                    samples = nil; phase = .idle
                    samplingProgress = nil; analysisStartedAt = nil; analysisProgress = nil; checkpoint = nil
                    errorMessage = (error as? MailOrganizationError)?.localizedDescription
                        ?? "Couldn't analyze these messages. Check the Google and ChatGPT connections, then try again."
                }
            }
        }
    }

    func applySelection() {
        guard canApply, let samples, let expected = snapshot else { return }
        let job = generation
        let selected = categories.filter(\.isSelected).map { category in
            OrganizationApplicationCategory(id: category.id,
                name: category.name.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: Self.applicationKind(category.proposal.kind),
                messageIDs: category.proposal.messageIDs.filter { category.selectedMessageIDs.contains($0) },
                ruleSenders: eligibleRuleSenders(for: category),
                createFilter: category.createsFilter && category.proposal.kind == .topic,
                existingLabelID: existingLabelID(for: category), backfillExisting: category.backfillExisting)
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

    private func eligibleRuleSenders(for category: MailOrganizationReviewCategory) -> [String] {
        guard category.proposal.kind == .topic else { return [] }
        return samples?.eligibleRuleSenders(category.proposal.ruleSenders,
                                            selectedMessageIDs: category.selectedMessageIDs) ?? []
    }

    private func existingLabelID(for category: MailOrganizationReviewCategory) -> String? {
        if let existingLabelID = category.existingLabelID { return existingLabelID }
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return samples?.existingLabels.first { !$0.isSystem && $0.name.lowercased() == name }?.id
    }

    private func ruleCoverage(for category: MailOrganizationReviewCategory) -> OrganizationRuleCoverage? {
        samples?.ruleCoverage(existingLabelID: existingLabelID(for: category), labelName: category.name,
                              proposedSenders: eligibleRuleSenders(for: category))
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

    private func observeAccess() {
        _ = withObservationTracking {
            access()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshAccess()
                observeAccess()
            }
        }
    }

    /// Canceling or finishing a session releases its samples and proposals.
    func clear() {
        generation = UUID(); operation?.cancel(); operation = nil
        samples = nil; categories = []; receipt = nil; delivery = nil
        samplingProgress = nil; analysisStartedAt = nil; analysisProgress = nil; checkpoint = nil
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

    private func analysisProgressCallback(_ job: UUID, _ expected: MailOrganizationAccess) -> AnalysisProgress {
        { [weak self] value in
            await MainActor.run {
                guard let self, self.generation == job else { return }
                self.refreshAccess()
                guard self.isCurrent(job, expected), self.phase == .analyzing else { return }
                self.analysisProgress = value
            }
        }
    }

    private func checkpointCallback(_ job: UUID, _ expected: MailOrganizationAccess) -> Checkpoint {
        { [weak self] value in
            await MainActor.run {
                guard let self, self.generation == job else { return }
                self.refreshAccess()
                guard self.isCurrent(job, expected), self.phase == .analyzing else { return }
                self.checkpoint = value
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
        case .staleLabels:
            return "An existing label changed. Analyze again before applying these suggestions."
        case .staleRules:
            return "An existing Gmail rule changed. Analyze again to review the current rule coverage."
        case .unsafeRule:
            return "These senders no longer support a future filter. Turn off the filter switches or analyze again."
        case .settingsPermissionRequired:
            return "Turn on Gmail Settings in Connections, or turn off the future filter switches."
        case .conflictingChange:
            return "Another label change is still pending. Let it finish, then try again."
        case .filterLimitReached:
            return "These suggestions would exceed Gmail's filter limit. Turn off some future filters and try again."
        case .invalidSelection:
            return "Check the selected label names, or analyze again to prepare a new review."
        }
    }
}
