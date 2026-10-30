import Foundation
import Observation
import SyncEngine
import TernAI

struct AssistantWritingStyleAccount: Equatable, Sendable {
    let id: String
    let email: String
    let displayName: String?
    let instanceID: String?
    let isMailAccessEnabled: Bool
}

struct AssistantWritingStyleEntry: Identifiable {
    enum State { case disabled, waiting, queued, reading, analyzing, ready, insufficient, failed }
    let id: String
    let email: String
    let displayName: String?
    let state: State
    let statusText: String
    let sampleCount: Int?
    let learnedAt: Date?
    let hasLimitedCoverage: Bool
    let summary: String?
    let isMailAccessEnabled: Bool
    var isLearning: Bool { state == .queued || state == .reading || state == .analyzing }
}

struct AssistantWritingStyleRound: Sendable {
    struct Hint: Sendable {
        let account: AssistantWritingStyleAccount
        let revision: UUID?
        let status: String
        let profile: WritingStyleProfile?
    }
    let requestID: UUID
    let hints: [String: Hint]

    func promptContext() throws -> String {
        let rows = try hints.keys.sorted().compactMap { id -> AIJSON? in
            guard let hint = hints[id] else { return nil }
            return .object([
                "account_id": .string(id), "email": .string(hint.account.email),
                "style_status": .string(hint.status),
                "preferences": try hint.profile.map { .string(try $0.promptContext()) } ?? .null,
            ])
        }
        guard !rows.isEmpty else { return "" }
        return """
        Writing-style context below is only for the matching sender account's draft body.
        It must not change your chat voice, supply facts, grant access, or override an explicit user request about style.
        If style learning becomes ready after a draft request, the tool may return draft_not_created; regenerate the draft with the next round's profile before calling prepare_draft again.
        If a draft reports style_applied:false, tell the user it uses the conversation and their request without a learned personal style.
        \(try AIJSON.array(rows).jsonString())
        """
    }
}

struct AssistantDraftStyleDecision: Sendable {
    let mayCreateDraft: Bool
    let styleApplied: Bool
    let status: String
    let note: String
}

@MainActor
@Observable
final class AssistantWritingStyleModel {
    typealias ReadSamples = @MainActor (AssistantWritingStyleAccount, @escaping @Sendable () async -> Bool) async throws -> AssistantWritingSamples
    typealias Analyze = @Sendable ([String], String, Date) async throws -> WritingStyleProfile?

    private(set) var storageErrorMessage: String?
    private var accounts: [AssistantWritingStyleAccount] = []
    private var archive = AssistantWritingStyleArchive()
    private var phases: [String: AssistantWritingStyleEntry.State] = [:]
    private var sampleCounts: [String: Int] = [:]
    private var modelID: String?
    private var connectionRevision = 0
    @ObservationIgnored private let store: any AssistantWritingStyleStore
    @ObservationIgnored private let readSamples: ReadSamples
    @ObservationIgnored private let analyze: Analyze
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let draftWaitLimit: Duration
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var attempts: [String: JobKey] = [:]
    @ObservationIgnored private var forced: Set<String> = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var currentJob: Job?
    @ObservationIgnored private var waitedRequests: [UUID: Set<String>] = [:]

    init(store: any AssistantWritingStyleStore, readSamples: @escaping ReadSamples,
         analyze: @escaping Analyze, now: @escaping @Sendable () -> Date = { .now },
         draftWaitLimit: Duration = .seconds(10)) {
        self.store = store; self.readSamples = readSamples; self.analyze = analyze
        self.now = now; self.draftWaitLimit = draftWaitLimit
        do { archive = try store.load(); try archive.validate() }
        catch { loadFailed = true; storageErrorMessage = "Saved writing styles could not be read. Choose Relearn to replace them." }
        archive.disabledAccountIDs.formUnion(store.disabledAccountIDs)
        let disabled = archive.disabledAccountIDs
        archive.profiles.removeAll { disabled.contains($0.accountID) }
    }

    var entries: [AssistantWritingStyleEntry] {
        accounts.map { account in
            let record = storedProfile(account)
            var count = sampleCounts[account.id] ?? record?.profile.sampleCount
            let state: AssistantWritingStyleEntry.State
            var text: String
            if !isEnabled(account.id) { state = .disabled; text = "Writing-style learning is off." }
            else if !account.isMailAccessEnabled { state = .waiting; text = "Enable mail access above to learn this account's style." }
            else if account.instanceID == nil { state = .waiting; text = "Sign in to this mail account to learn its style." }
            else if loadFailed { state = .failed; text = "Saved style is unavailable. Choose Relearn to replace it." }
            else if let phase = phases[account.id], phase == .reading || phase == .analyzing {
                state = phase
                text = phase == .reading ? "Reading up to 100 sent messages…" : "Learning from \(count ?? 0) sent messages…"
            } else if phases[account.id] == .queued { state = .queued; text = "Waiting to learn this account's style…" }
            else if phases[account.id] == .failed {
                state = .failed
                if let record { count = record.profile.sampleCount; text = "Couldn't relearn the style. The previous profile is still available." }
                else { text = "Couldn't learn a writing style. Choose Relearn to try again." }
            } else if phases[account.id] == .insufficient {
                state = .insufficient
                text = "Not enough usable writing in \(count ?? 0) sent messages."
                if record != nil { text += " The previous profile is still available." }
            } else if let record { state = .ready; text = "Learned from \(record.profile.sampleCount) sent messages." }
            else if modelID == nil { state = .waiting; text = "Connect ChatGPT and choose a model to learn this style." }
            else { state = .queued; text = "Waiting to learn this account's style…" }
            return AssistantWritingStyleEntry(id: account.id, email: account.email, displayName: account.displayName,
                state: state, statusText: text, sampleCount: count, learnedAt: record?.profile.profiledAt,
                hasLimitedCoverage: record?.hasLimitedCoverage ?? false, summary: record.map { Self.summary($0.profile) },
                isMailAccessEnabled: account.isMailAccessEnabled)
        }
    }

    func isEnabled(_ id: String) -> Bool { !archive.disabledAccountIDs.contains(id) }

    func canRelearn(_ id: String) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        return isEnabled(id) && account.isMailAccessEnabled && account.instanceID != nil && modelID != nil
            && currentJob?.key.account.id != id && entries.first(where: { $0.id == id })?.isLearning != true
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        if enabled { archive.disabledAccountIDs.remove(id) }
        else { archive.disabledAccountIDs.insert(id); archive.profiles.removeAll { $0.accountID == id } }
        phases.removeValue(forKey: id); sampleCounts.removeValue(forKey: id); attempts.removeValue(forKey: id)
        forced.remove(id)
        if currentJob?.key.account.id == id { currentJob = nil; runner?.cancel() }
        if loadFailed {
            do { try store.setDisabledAccountIDs(archive.disabledAccountIDs) }
            catch { storageErrorMessage = "The saved styles are unreadable, and the learning preference could not be saved." }
        } else { persist() }
        startIfNeeded()
    }

    func forgetAccount(_ id: String) {
        archive.profiles.removeAll { $0.accountID == id }
        archive.disabledAccountIDs.remove(id)
        accounts.removeAll { $0.id == id }
        phases.removeValue(forKey: id); sampleCounts.removeValue(forKey: id)
        attempts.removeValue(forKey: id); forced.remove(id)
        for key in waitedRequests.keys { waitedRequests[key]?.remove(id) }
        if currentJob?.key.account.id == id { currentJob = nil; runner?.cancel() }
        if loadFailed {
            do { try store.setDisabledAccountIDs(archive.disabledAccountIDs) }
            catch { storageErrorMessage = "The account's writing-style preference could not be removed." }
        } else { persist() }
        startIfNeeded()
    }

    func relearn(_ id: String) {
        guard canRelearn(id) else { return }
        loadFailed = false; storageErrorMessage = nil
        attempts.removeValue(forKey: id); forced.insert(id); phases[id] = .queued
        startIfNeeded()
    }

    /// Nil model means ChatGPT is unavailable. That cancels work while retaining
    /// local profiles; an unready account list never prunes stored preferences.
    func refresh(accounts: [AssistantWritingStyleAccount], accountListReady: Bool,
                 connectionRevision: Int, modelID: String?) {
        self.accounts = accounts; self.connectionRevision = connectionRevision; self.modelID = modelID
        var changed = false
        if accountListReady {
            let ids = Set(accounts.map(\.id))
            let previous = archive
            let disabled = archive.disabledAccountIDs
            archive.profiles.removeAll { profile in
                guard let account = accounts.first(where: { $0.id == profile.accountID }) else { return true }
                return !account.isMailAccessEnabled || disabled.contains(account.id) || !Self.sameEmail(profile.email, account.email)
            }
            archive.disabledAccountIDs.formIntersection(ids)
            changed = previous != archive
            for (id, _) in attempts where !accounts.contains(where: { $0.id == id && $0.isMailAccessEnabled && $0.instanceID != nil }) {
                attempts.removeValue(forKey: id); phases.removeValue(forKey: id); sampleCounts.removeValue(forKey: id)
            }
        }
        if let currentJob, !isCurrent(currentJob) {
            phases.removeValue(forKey: currentJob.key.account.id)
            if attempts[currentJob.key.account.id] == currentJob.key { attempts.removeValue(forKey: currentJob.key.account.id) }
            self.currentJob = nil
            runner?.cancel()
        }
        if changed, !loadFailed { persist() }
        startIfNeeded()
    }

    func round(accountIDs: Set<String>, requestID: UUID) -> AssistantWritingStyleRound {
        let hints = accounts.filter { accountIDs.contains($0.id) && $0.isMailAccessEnabled && $0.instanceID != nil }.map { account in
            let record = isEnabled(account.id) ? storedProfile(account) : nil
            let status = !isEnabled(account.id) ? "off" : (record != nil ? "ready" : fallbackStatus(account.id))
            return (account.id, AssistantWritingStyleRound.Hint(account: account, revision: record?.revision, status: status, profile: record?.profile))
        }
        return AssistantWritingStyleRound(requestID: requestID, hints: Dictionary(uniqueKeysWithValues: hints))
    }

    func draftDecision(accountID: String, round: AssistantWritingStyleRound?) async throws -> AssistantDraftStyleDecision {
        guard let account = accounts.first(where: { $0.id == accountID }), account.isMailAccessEnabled,
              account.instanceID != nil else { throw CancellationError() }
        let revision = connectionRevision
        if isEnabled(accountID), storedProfile(account) == nil, fallbackStatus(accountID) == "pending",
           let round, waitedRequests[round.requestID]?.contains(accountID) != true {
            if waitedRequests.count >= 32 { waitedRequests.removeAll() }
            waitedRequests[round.requestID, default: []].insert(accountID)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: draftWaitLimit)
            while clock.now < deadline, isEnabled(accountID), storedProfile(account) == nil,
                  fallbackStatus(accountID) == "pending" {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                guard connectionRevision == revision, accounts.contains(account) else { throw CancellationError() }
            }
        }
        try Task.checkCancellation()
        guard connectionRevision == revision, accounts.contains(account) else { throw CancellationError() }
        if !isEnabled(accountID) {
            if round?.hints[accountID]?.profile != nil {
                return .init(mayCreateDraft: false, styleApplied: false, status: "style_changed",
                    note: "Writing-style learning was turned off. No draft was created. Prepare it again without the earlier style profile.")
            }
            return fallbackDecision("off")
        }
        if let record = storedProfile(account) {
            guard let hint = round?.hints[accountID], hint.account == account, hint.revision == record.revision else {
                return .init(mayCreateDraft: false, styleApplied: false, status: "style_ready",
                    note: "The writing style is now ready. No draft was created from the earlier text. Prepare it again using the current profile.")
            }
            return .init(mayCreateDraft: true, styleApplied: true, status: "ready",
                         note: "This account's writing preferences were supplied for the draft, with your instructions taking precedence.")
        }
        if round?.hints[accountID]?.profile != nil {
            return .init(mayCreateDraft: false, styleApplied: false, status: "style_changed",
                note: "The writing profile used for this text is no longer available. No draft was created. Prepare it again using the current context.")
        }
        let status = fallbackStatus(accountID)
        if status == "pending" {
            return .init(mayCreateDraft: false, styleApplied: false, status: "pending",
                note: "Your writing style is still being learned. No draft was created. Wait for learning to finish before trying again.")
        }
        return fallbackDecision(status)
    }

    func waitForLearning() async {
        while let active = runner { await active.value }
    }

    /// Used by the draft engine immediately before its commit. This never waits
    /// or starts learning, and rejects bodies generated under replaced policy.
    func isDraftDecisionCurrent(accountID: String, round: AssistantWritingStyleRound?,
                                decision: AssistantDraftStyleDecision) -> Bool {
        guard decision.mayCreateDraft, let account = accounts.first(where: { $0.id == accountID }),
              account.isMailAccessEnabled, account.instanceID != nil else { return false }
        if decision.styleApplied {
            guard isEnabled(accountID), let record = storedProfile(account), let hint = round?.hints[accountID] else { return false }
            return hint.account == account && hint.revision == record.revision
        }
        if decision.status == "off" { return !isEnabled(accountID) }
        return isEnabled(accountID) && storedProfile(account) == nil && fallbackStatus(accountID) == decision.status
    }

    private struct JobKey: Equatable, Sendable {
        let account: AssistantWritingStyleAccount
        let connectionRevision: Int
        let model: String
    }
    private struct Job: Sendable { let id = UUID(); let key: JobKey }
    private enum LearningError: Error { case unavailableSamples }

    private func nextJob() -> Job? {
        guard !loadFailed, let modelID else { return nil }
        for account in accounts where account.isMailAccessEnabled && account.instanceID != nil && isEnabled(account.id) {
            let key = JobKey(account: account, connectionRevision: connectionRevision, model: modelID)
            if (storedProfile(account) == nil || forced.contains(account.id)), attempts[account.id] != key { return Job(key: key) }
        }
        return nil
    }

    private func startIfNeeded() {
        guard runner == nil, nextJob() != nil else { return }
        runner = Task { [weak self] in await self?.learnPendingAccounts() }
    }

    private func learnPendingAccounts() async {
        defer { runner = nil; currentJob = nil; startIfNeeded() }
        while !Task.isCancelled, let job = nextJob() {
            currentJob = job
            let account = job.key.account
            attempts[account.id] = job.key; forced.remove(account.id); phases[account.id] = .reading
            do {
                let samples = try await readSamples(account) { [weak self] in
                    await MainActor.run { self?.isCurrent(job) == true }
                }
                try Task.checkCancellation()
                guard isCurrent(job), samples.accountID == account.id else { throw CancellationError() }
                sampleCounts[account.id] = samples.samples.count
                guard !samples.samples.isEmpty || samples.failures.isEmpty else { throw LearningError.unavailableSamples }
                phases[account.id] = .analyzing
                let profile = try await analyze(samples.samples.map(\.text), job.key.model, now())
                try Task.checkCancellation()
                guard isCurrent(job) else { throw CancellationError() }
                guard let profile else { phases[account.id] = .insufficient; currentJob = nil; continue }
                try profile.validate()
                guard profile.sampleCount <= samples.samples.count else { throw WritingStyleError.invalidProfile }
                let record = AssistantStoredWritingStyle(accountID: account.id, email: account.email, revision: UUID(),
                    profile: profile, hasLimitedCoverage: samples.truncated || samples.skippedCount > 0
                        || !samples.failures.isEmpty || profile.sampleCount < samples.selectedCount)
                var updated = archive
                updated.profiles.removeAll { $0.accountID == account.id }; updated.profiles.append(record)
                do { try store.save(updated) }
                catch { storageErrorMessage = "Tern could not save the learned writing style. No new profile was stored."; throw error }
                guard isCurrent(job) else { throw CancellationError() }
                archive = updated; phases[account.id] = .ready; storageErrorMessage = nil
            } catch {
                if isCurrent(job) {
                    phases[account.id] = .failed
                }
            }
            currentJob = nil
        }
    }

    private func isCurrent(_ job: Job) -> Bool {
        currentJob?.id == job.id && connectionRevision == job.key.connectionRevision && modelID == job.key.model
            && accounts.contains(job.key.account) && job.key.account.isMailAccessEnabled
            && job.key.account.instanceID != nil && isEnabled(job.key.account.id)
    }

    private func storedProfile(_ account: AssistantWritingStyleAccount) -> AssistantStoredWritingStyle? {
        archive.profiles.first { $0.accountID == account.id && Self.sameEmail($0.email, account.email) }
    }

    private func fallbackStatus(_ id: String) -> String {
        if loadFailed || phases[id] == .failed { return "unavailable" }
        if phases[id] == .insufficient { return "insufficient" }
        return modelID == nil ? "unavailable" : "pending"
    }

    private func fallbackDecision(_ status: String) -> AssistantDraftStyleDecision {
        .init(mayCreateDraft: true, styleApplied: false, status: status,
              note: status == "off" ? "Writing-style learning is off. This draft uses the conversation and your request."
                  : "A learned writing style is unavailable. This draft uses the conversation and your request.")
    }

    private func persist() {
        do { try store.save(archive); storageErrorMessage = nil }
        catch { storageErrorMessage = "Tern could not update the saved profile file. Profile use has stopped for disabled accounts, but the file may still contain their previous styles." }
    }

    private static func sameEmail(_ lhs: String, _ rhs: String) -> Bool { lhs.lowercased() == rhs.lowercased() }
    private static func summary(_ profile: WritingStyleProfile) -> String {
        [profile.traits.formality.rawValue, profile.traits.detail.rawValue, profile.traits.directness.rawValue]
            .filter { $0 != "undetermined" && $0 != "mixed" }.map { $0.capitalized }.joined(separator: " · ")
    }
}
