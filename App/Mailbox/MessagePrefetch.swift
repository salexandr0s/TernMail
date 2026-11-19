import SwiftUI
import MailStore
import MessageContent

/// Keeps a few conversations near the selection ready to read. The ordered
/// rows already reflect the mailbox's account scope, filters and sort order.
struct MessagePrefetchPlan: Equatable {
    let keys: [ThreadKey]
    let accounts: [ObjectIdentifier]
    /// Different selections can have identical neighbours; each restarts idle time.
    let selected: Set<MailListRowID>

    static func candidates(rows: [MailListRowID], selected: Set<MailListRowID>) -> [ThreadKey] {
        var ordered: [MailListRowID]
        if selected.count == 1, let index = rows.firstIndex(where: selected.contains) {
            // Prefer the next messages, then the previous one. Skip siblings
            // from the selected conversation because its reader loads them.
            let nearby = [index + 1, index + 2, index - 1, index + 3, index - 2]
            ordered = nearby.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        } else {
            ordered = Array(rows.prefix(8))
        }
        var seen = Set(selected.map(\.threadKey))
        ordered = ordered.filter { seen.insert($0.threadKey).inserted }
        return Array(ordered.prefix(4).map(\.threadKey))
    }
}

/// Records which open conversations can be read, so neighbour prefetch follows
/// the selected conversation instead of competing with it. It only affects
/// timing: without an answer, prefetch starts at its limit.
@MainActor
final class ReaderReadiness {
    static let shared = ReaderReadiness()
    private var readable: Set<ThreadKey> = []
    private var waiters: [ThreadKey: [UUID: AsyncStream<Void>.Continuation]] = [:]

    /// The active reader showing `key` has its first body on screen.
    func markReadable(_ key: ThreadKey) {
        guard readable.insert(key).inserted, let waiting = waiters.removeValue(forKey: key) else { return }
        for continuation in waiting.values { continuation.finish() }
    }

    /// The reader showing `key` was hidden, closed or given another conversation.
    func clear(_ key: ThreadKey) { readable.remove(key) }

    func isReadable(_ key: ThreadKey) -> Bool { readable.contains(key) }

    /// Returns once `key` can be read, or when the calling task is cancelled.
    func waitUntilReadable(_ key: ThreadKey) async {
        guard !readable.contains(key) else { return }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters[key, default: [:]][id] = continuation
        defer {
            waiters[key]?[id] = nil
            if waiters[key]?.isEmpty == true { waiters[key] = nil }
        }
        // Nothing is yielded. The stream ends when the conversation is
        // readable or this task is cancelled.
        for await _ in stream {}
    }
}

/// Gives selection a short quiet interval, then waits for the selected
/// conversation to be readable, before starting either hydration or
/// preparation. Engine submissions and cleanup stay ordered; network work does not.
@MainActor
final class MessagePrefetchController {
    private var submittedOwners: [AccountMailbox] = []
    private var updateTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let delay: Duration
    private let foregroundLimit: Duration
    private let readiness: ReaderReadiness
    private let waitUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    init(delay: Duration? = nil, foregroundLimit: Duration = .milliseconds(400), readiness: ReaderReadiness? = nil,
         waitUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.delay = delay ?? Self.defaultDelay
        self.foregroundLimit = foregroundLimit
        self.readiness = readiness ?? .shared
        self.waitUntil = waitUntil
    }

    private static var defaultDelay: Duration {
        #if TERN_TEST_SUPPORT || TERN_PERFORMANCE
        // Fixed diagnostic comparison; cleanup and foreground behavior are identical.
        if LaunchMode.current.performance.readerPrefetchImmediate { return .zero }
        #endif
        return .milliseconds(90)
    }

    /// `foreground` is the conversation the selection opens. Its neighbours
    /// start once it can be read, or at the limit when that takes longer.
    @discardableResult
    func update(keys: [ThreadKey], accounts: [AccountMailbox], mailbox: MailboxModel? = nil,
                foreground: ThreadKey? = nil) -> Task<Void, Never> {
        generation &+= 1
        let requestedGeneration = generation
        let selectedAt = ContinuousClock.now
        let deadline = selectedAt.advanced(by: delay)
        let foregroundDeadline = selectedAt.advanced(by: foregroundLimit)
        prepareTask?.cancel()
        prepareTask = nil
        updateTask?.cancel()
        let active = accounts.filter(\.syncEnabled)
        let previousUpdate = updateTask
        let task = Task {
            await previousUpdate?.value
            // Never skip cleanup, even if this update was superseded while it
            // waited. A later update cannot submit until this one has finished.
            let previousOwners = submittedOwners
            submittedOwners = []
            for owner in previousOwners {
                await owner.engine.prefetchThreads([])
            }
            guard isCurrent(requestedGeneration), !keys.isEmpty, !active.isEmpty else { return }
            do { try await waitUntil(deadline) } catch { return }
            guard isCurrent(requestedGeneration) else { return }
            // The immediate diagnostic mode has no quiet interval, so it doesn't wait here either.
            if let foreground, delay > .zero {
                await waitForForeground(foreground, until: foregroundDeadline)
                guard isCurrent(requestedGeneration) else { return }
            }
            for owner in active {
                guard isCurrent(requestedGeneration) else { return }
                if let mailbox, mailbox.account(id: owner.account.id) !== owner { continue }
                let ids = keys.filter { $0.accountID == owner.account.id }.map(\.threadID)
                guard !ids.isEmpty else { continue }
                // Cancellation during this actor hop must not lose the engine
                // whose background plan the next update needs to clear.
                submittedOwners.append(owner)
                await owner.engine.prefetchThreads(ids)
            }
            guard isCurrent(requestedGeneration), let mailbox else { return }
            prepareTask = Task {
                for key in keys {
                    guard isCurrent(requestedGeneration) else { return }
                    guard let owner = active.first(where: { $0.account.id == key.accountID }),
                          mailbox.account(id: key.accountID) === owner else { continue }
                    await Self.prepare(key, owner: owner, mailbox: mailbox)
                }
            }
        }
        updateTask = task
        return task
    }

    @discardableResult
    func stop() -> Task<Void, Never> { update(keys: [], accounts: []) }

    private func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        !Task.isCancelled && generation == requestedGeneration
    }

    /// Speculative work stays out of the open it follows. The limit covers a
    /// selected conversation that is slow, not on screen or never readable.
    private func waitForForeground(_ key: ThreadKey, until limit: ContinuousClock.Instant) async {
        guard !readiness.isReadable(key) else { return }
        let readiness = readiness, waitUntil = waitUntil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await waitUntil(limit) }
            group.addTask { await readiness.waitUntilReadable(key) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func checkOwner(_ owner: AccountMailbox, mailbox: MailboxModel) throws {
        try Task.checkCancellation()
        guard mailbox.account(id: owner.account.id) === owner else { throw CancellationError() }
    }

    /// Reads the conversation off the main actor. The caller has checked the
    /// account, and `cachePrepared` checks it again before each document is kept.
    private nonisolated static func prepare(_ key: ThreadKey, owner: AccountMailbox, mailbox: MailboxModel) async {
        do {
            let cache = mailbox.cache
            try await owner.engine.prepareReadingThread(key.threadID)
            for try await detail in cache.thread(accountID: key.accountID, threadID: key.threadID) {
                guard let detail else { return }
                try Task.checkCancellation()
                let expanded = ReadingPreferences.initiallyExpanded(ids: detail.messages.map(\.id),
                    unread: Set(detail.messages.filter(\.isUnread).map(\.id)), selected: nil)
                let defaults = UserDefaults.standard
                let blocks = defaults.object(forKey: ReadingPreferences.blockImagesKey) as? Bool ?? true
                let scale = ReadingPreferences.textScale(defaults.object(forKey: ReadingPreferences.textScaleKey) as? Double ?? 1)
                let messages = defaults.string(forKey: ReadingPreferences.orderKey) == ReadingPreferences.Order.newestFirst.rawValue
                    ? Array(detail.messages.reversed()) : detail.messages
                for message in messages.filter({ expanded.contains($0.id) }).prefix(2) {
                    try Task.checkCancellation()
                    guard let body = message.body else { continue }
                    let messageID = message.id
                    let resources = try await cache.read { tx in
                        ReadingResourceSnapshot(resources: try tx.mimeResources(messageID: messageID, accountID: key.accountID))
                    }
                    let sender = SenderImageIdentity(accountID: key.accountID, messageID: messageID, from: message.record.sender,
                        verifiedSender: message.record.verifiedImageSender)
                    try await cachePrepared(body, resources: resources, sender: sender, blocksImages: blocks, textScale: scale,
                                            owner: owner, mailbox: mailbox)
                }
                return
            }
        } catch { /* Selection retries required content in the foreground lane. */ }
    }

    /// The account check, the image permission, the rule list and the prepared
    /// cache belong to the main actor. Parsing runs on the cache's speculative lane.
    private static func cachePrepared(_ body: MessageBodyRecord, resources: ReadingResourceSnapshot, sender: SenderImageIdentity,
                                      blocksImages: Bool, textScale: Double,
                                      owner: AccountMailbox, mailbox: MailboxModel) async throws {
        try checkOwner(owner, mailbox: mailbox)
        // The reader's own rule, so the document is prepared under the permission it will be read with.
        let senders = owner.imageSenders
        await senders.load(from: mailbox.accountStore)
        let allowsImages = sender.allowsImages(blocksRemoteImages: blocksImages, explicit: nil, remembered: senders.remembered(sender))
        let rules = await RemoteContentBlocker.ruleList(allowsRemoteImages: allowsImages)
        try checkOwner(owner, mailbox: mailbox)
        let cacheKey = ReaderPreparationKey(accountID: sender.accountID, owner: ObjectIdentifier(owner), messageID: sender.messageID,
            body: ReaderBodyVersion(body), resourcesRevision: resources.revision, allowsImages: allowsImages,
            textOnly: rules == nil, textScale: textScale)
        _ = try await ReaderPreparedCache.shared.prepare(key: cacheKey, body: body, resources: resources.resources, isSpeculative: true)
    }
}

struct MessagePrefetchModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    @State private var controller = MessagePrefetchController()

    private var plan: MessagePrefetchPlan {
        guard app.destination == .mail, !mailbox.showsAttachmentLibrary else {
            return MessagePrefetchPlan(keys: [], accounts: [], selected: [])
        }
        return MessagePrefetchPlan(
            keys: MessagePrefetchPlan.candidates(rows: mailbox.listRowIDs, selected: mailbox.selectedListRowIDs),
            accounts: mailbox.accounts.map(ObjectIdentifier.init),
            selected: mailbox.selectedListRowIDs
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: plan, initial: true) { _, plan in
                MessageWebViewWarmup.start(for: .init(listHasRows: !plan.keys.isEmpty, hasSelection: !plan.selected.isEmpty))
                controller.update(keys: plan.keys, accounts: plan.accounts.isEmpty ? [] : mailbox.accounts, mailbox: mailbox,
                                  foreground: plan.selected.count == 1 ? plan.selected.first?.threadKey : nil)
            }
            .task(id: plan.accounts) {
                // Read each account's remembered image senders before a
                // conversation is opened, so its first render doesn't wait for them.
                guard !plan.accounts.isEmpty else { return }
                for account in mailbox.accounts {
                    await account.imageSenders.load(from: mailbox.accountStore)
                }
            }
            .onDisappear { controller.stop() }
    }
}
