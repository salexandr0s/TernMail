import Foundation
import MailStore
import Observation

@MainActor @Observable
final class CacheMaintenanceModel {
    static let budgetKey = "tern.cacheBudgetMiB"
    static let defaultBudgetMiB = 2048
    static let budgetChoices = [256, 512, 1024, 2048, 4096, 8192]
    private static let batchLimit = 128

    private(set) var usage = CacheUsage()
    private(set) var readiness: CacheResetReadiness?
    private(set) var isRefreshing = false
    private(set) var isTrimming = false
    private(set) var protectedBudgetLimit = false
    var error: String?
    var status: String?
    @ObservationIgnored private let cacheProvider: () -> MailCache?
    @ObservationIgnored private let storeProvider: () -> AccountStore?
    @ObservationIgnored private let keeping: () -> Set<CacheThreadReference>
    @ObservationIgnored private let mayMaintain: () -> Bool
    @ObservationIgnored private let attachmentDirectory: URL
    @ObservationIgnored private let budgetOverride: Int64?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var trimTask: Task<Void, Never>?

    init(app: AppModel) {
        cacheProvider = { [weak app] in app?.cache }
        storeProvider = { [weak app] in app?.settingsAccountStore }
        keeping = { [weak app] in
            let visible = app?.visibleConversationKeys ?? []
            let selected = app?.mailbox?.selectedThreadIDs ?? []
            return Set(visible.union(selected).map { CacheThreadReference(accountID: $0.accountID, threadID: $0.threadID) })
        }
        mayMaintain = { [weak app] in app?.isResettingCache == false }
        attachmentDirectory = app.mailbox?.downloadsDirectory ?? MailboxModel.defaultDownloadsDirectory
        budgetOverride = nil
        defaults = .standard
        now = { .now }
    }

    /// Injected stores and a small byte budget keep verification independent
    /// of a real mailbox, the user's Downloads and the app's cache directory.
    init(cache: MailCache, store: AccountStore?, attachmentDirectory: URL, budgetBytes: Int64,
         keeping: @escaping () -> Set<CacheThreadReference> = { [] }, now: @escaping () -> Date = { .now }) {
        cacheProvider = { cache }; storeProvider = { store }; self.keeping = keeping
        mayMaintain = { true }; self.attachmentDirectory = attachmentDirectory; budgetOverride = max(0, budgetBytes)
        defaults = .standard; self.now = now
    }

    var totalBytes: Int64 { usage.databaseBytes + usage.downloadedAttachmentBytes }
    var budgetMiB: Int {
        let value = defaults.object(forKey: Self.budgetKey) == nil ? Self.defaultBudgetMiB : defaults.integer(forKey: Self.budgetKey)
        return Self.budgetChoices.contains(value) ? value : Self.defaultBudgetMiB
    }
    private var budgetBytes: Int64 { budgetOverride ?? Int64(budgetMiB) * 1024 * 1024 }

    func refresh() async {
        guard !isRefreshing, let cache = cacheProvider() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do { try await measure(cache) }
        catch { self.error = "Couldn't measure the mail cache."; readiness = nil }
    }

    /// Reset and quit cancel and join maintenance before replacing cache state.
    func suspend() async {
        suspended = true
        trimTask?.cancel()
        await trimTask?.value
    }
    func resume() { suspended = false }

    func enforceBudget() async {
        guard trimTask == nil, !suspended, mayMaintain(), !Task.isCancelled else { return }
        let task = Task { await performTrim() }
        trimTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        trimTask = nil
    }

    private var canContinue: Bool { !suspended && mayMaintain() && !Task.isCancelled }

    private func performTrim() async {
        guard let cache = cacheProvider(), canContinue else { return }
        isTrimming = true
        error = nil
        protectedBudgetLimit = false
        defer { isTrimming = false }
        do {
            try await measure(cache)
            guard canContinue, totalBytes > budgetBytes else { status = "Cache is within its budget."; return }
            guard readiness?.canReset == true else {
                protectedBudgetLimit = true
                status = "Finish or discard drafts and queued changes before trimming."
                return
            }
            let initialProtection = try await protectedThreads()
            let candidates = try await cache.evictionCandidates(keeping: initialProtection, now: now())
            let batch = try await actionableBatch(from: candidates, in: cache)
            var estimated = totalBytes
            var changed = false
            // Content and managed files go first, in last-opened order.
            for candidate in batch {
                guard canContinue, estimated > budgetBytes else { break }
                let currentReadiness = try await cache.cacheResetReadiness()
                guard currentReadiness.canReset else { readiness = currentReadiness; break }
                let records = try await attachments(for: candidate.thread, in: cache)
                let protection = try await protectedThreads()
                let result = try await cache.evictContent(for: [candidate.thread], keeping: protection, now: now())
                guard canContinue else { break }
                if result.evictedThreads.contains(candidate.thread) {
                    changed = changed || result.releasedContentBytes > 0
                    estimated = max(0, estimated - result.releasedContentBytes)
                    let currentProtection = try await protectedThreads()
                    guard canContinue else { break }
                    if !currentProtection.contains(candidate.thread) {
                        for folder in ManagedAttachmentFiles.folders(for: records, in: attachmentDirectory) {
                            guard canContinue else { break }
                            let removed = try ManagedAttachmentFiles.remove(folder, within: attachmentDirectory, now: now(),
                                protectedURLs: AttachmentPreviewRegistry.shared.activeURLs)
                            changed = changed || removed > 0
                            estimated = max(0, estimated - removed)
                        }
                    }
                }
            }
            // Metadata is limited to the store's old, unheld candidates. Keep
            // metadata for recent file copies so a later pass can still map them.
            if canContinue, estimated > budgetBytes {
                for candidate in batch where candidate.canEvictMetadata {
                    guard canContinue else { break }
                    let currentReadiness = try await cache.cacheResetReadiness()
                    guard currentReadiness.canReset else { readiness = currentReadiness; break }
                    let records = try await attachments(for: candidate.thread, in: cache)
                    let folders = ManagedAttachmentFiles.folders(for: records, in: attachmentDirectory)
                    guard folders.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path)
                        || ManagedAttachmentFiles.canRemove($0, within: attachmentDirectory, now: now(),
                            protectedURLs: AttachmentPreviewRegistry.shared.activeURLs) }) else { continue }
                    let protection = try await protectedThreads()
                    let result = try await cache.evictMetadata(for: [candidate.thread], keeping: protection, now: now())
                    changed = changed || result.deletedMessageCount > 0
                    guard canContinue else { break }
                    let currentProtection = try await protectedThreads()
                    guard canContinue else { break }
                    if result.evictedThreads.contains(candidate.thread), !currentProtection.contains(candidate.thread) {
                        for folder in folders {
                            _ = try ManagedAttachmentFiles.remove(folder, within: attachmentDirectory, now: now(),
                                protectedURLs: AttachmentPreviewRegistry.shared.activeURLs)
                        }
                    }
                }
            }
            guard canContinue else { return }
            if changed { try await cache.compactDisposableCache() }
            try await measure(cache)
            guard canContinue else { return }
            if totalBytes <= budgetBytes { status = "Cache trimmed to its budget." }
            else {
                let protection = try await protectedThreads()
                let remaining = try await cache.evictionCandidates(keeping: protection, now: now())
                protectedBudgetLimit = try await actionableBatch(from: remaining, in: cache).isEmpty
                status = protectedBudgetLimit
                    ? "The remaining cache is protected or recently used. It currently exceeds the budget."
                    : "This pass trimmed older mail. Another pass will continue toward the budget."
            }
        } catch is CancellationError {
        } catch { self.error = "Couldn't finish trimming the mail cache. Try again." }
    }

    /// Empty recent/Inbox metadata must not repeatedly consume the pass cap.
    private func actionableBatch(from candidates: [CacheEvictionCandidate], in cache: MailCache) async throws -> [CacheEvictionCandidate] {
        var batch: [CacheEvictionCandidate] = []
        for candidate in candidates {
            guard canContinue, batch.count < Self.batchLimit else { break }
            if candidate.disposableBytes > 0 { batch.append(candidate); continue }
            let records = try await attachments(for: candidate.thread, in: cache)
            let folders = ManagedAttachmentFiles.folders(for: records, in: attachmentDirectory)
            let removable = folders.contains { folder in
                FileManager.default.fileExists(atPath: folder.path)
                    && ManagedAttachmentFiles.canRemove(folder, within: attachmentDirectory, now: now(),
                        protectedURLs: AttachmentPreviewRegistry.shared.activeURLs)
            }
            let noRetainedFiles = folders.allSatisfy { folder in
                !FileManager.default.fileExists(atPath: folder.path)
                    || ManagedAttachmentFiles.canRemove(folder, within: attachmentDirectory, now: now(),
                        protectedURLs: AttachmentPreviewRegistry.shared.activeURLs)
            }
            if removable || (candidate.canEvictMetadata && noRetainedFiles) { batch.append(candidate) }
        }
        return batch
    }

    private func protectedThreads() async throws -> Set<CacheThreadReference> {
        var protected = keeping()
        if let store = storeProvider() {
            for alert in try await store.pendingMailAlerts() {
                protected.insert(.init(accountID: alert.accountID, threadID: alert.threadID))
            }
        }
        return protected
    }

    private func attachments(for thread: CacheThreadReference, in cache: MailCache) async throws -> [AttachmentRecord] {
        try await cache.read { tx in
            try tx.messages(threadID: thread.threadID, accountID: thread.accountID).flatMap {
                try tx.attachments(messageID: $0.id, accountID: thread.accountID)
            }
        }
    }

    private func measure(_ cache: MailCache) async throws {
        var measured = try await cache.disposableContentUsage()
        let directory = attachmentDirectory
        measured.downloadedAttachmentBytes = await Task.detached { ManagedAttachmentFiles.totalBytes(in: directory) }.value
        readiness = try await cache.cacheResetReadiness()
        usage = measured
    }
}
