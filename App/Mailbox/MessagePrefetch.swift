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

/// Gives selection a short quiet interval before starting either hydration or
/// preparation. Engine submissions and cleanup stay ordered; network work does not.
@MainActor
final class MessagePrefetchController {
    private var submittedOwners: [AccountMailbox] = []
    private var updateTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let delay: Duration
    private let waitUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    init(delay: Duration? = nil,
         waitUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.delay = delay ?? Self.defaultDelay
        self.waitUntil = waitUntil
    }

    private static var defaultDelay: Duration {
        #if DEBUG || TERN_PERFORMANCE
        // Fixed diagnostic comparison; cleanup and foreground behavior are identical.
        if ProcessInfo.processInfo.arguments.contains("--reader-prefetch-immediate") { return .zero }
        #endif
        return .milliseconds(90)
    }

    @discardableResult
    func update(keys: [ThreadKey], accounts: [AccountMailbox], mailbox: MailboxModel? = nil) -> Task<Void, Never> {
        generation &+= 1
        let requestedGeneration = generation
        let deadline = ContinuousClock.now.advanced(by: delay)
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

    private static func checkOwner(_ owner: AccountMailbox, mailbox: MailboxModel) throws {
        try Task.checkCancellation()
        guard mailbox.account(id: owner.account.id) === owner else { throw CancellationError() }
    }

    private static func prepare(_ key: ThreadKey, owner: AccountMailbox, mailbox: MailboxModel) async {
        do {
            try checkOwner(owner, mailbox: mailbox)
            try await owner.engine.prepareReadingThread(key.threadID)
            try checkOwner(owner, mailbox: mailbox)
            for try await detail in mailbox.cache.thread(accountID: key.accountID, threadID: key.threadID) {
                guard let detail, !Task.isCancelled, mailbox.account(id: key.accountID) === owner else { return }
                let expanded = ReadingPreferences.initiallyExpanded(ids: detail.messages.map(\.id),
                    unread: Set(detail.messages.filter(\.isUnread).map(\.id)), selected: nil)
                let defaults = UserDefaults.standard
                let blocks = defaults.object(forKey: ReadingPreferences.blockImagesKey) as? Bool ?? true
                let allowed = (try? await mailbox.accountStore?.allowedImageSenders(accountID: key.accountID)) ?? []
                try checkOwner(owner, mailbox: mailbox)
                let scale = ReadingPreferences.textScale(defaults.object(forKey: ReadingPreferences.textScaleKey) as? Double ?? 1)
                let messages = defaults.string(forKey: ReadingPreferences.orderKey) == ReadingPreferences.Order.newestFirst.rawValue
                    ? Array(detail.messages.reversed()) : detail.messages
                for message in messages.filter({ expanded.contains($0.id) }).prefix(2) {
                    try Task.checkCancellation()
                    guard let body = message.body else { continue }
                    let messageID = message.id
                    let resources = try await mailbox.cache.read { tx in
                        ReadingResourceSnapshot(resources: try tx.mimeResources(messageID: messageID, accountID: key.accountID))
                    }
                    try checkOwner(owner, mailbox: mailbox)
                    let sender = EmailAddress.parseList(message.record.sender).first?.address.lowercased() ?? ""
                    let images = !blocks || allowed.contains(sender)
                    let rules = await RemoteContentBlocker.ruleList(allowsRemoteImages: images)
                    try checkOwner(owner, mailbox: mailbox)
                    let cacheKey = ReaderPreparationKey(accountID: key.accountID, owner: ObjectIdentifier(owner), messageID: messageID,
                        body: ReaderBodyVersion(body), resourcesRevision: resources.revision, allowsImages: images, textOnly: rules == nil, textScale: scale)
                    _ = try await ReaderPreparedCache.shared.prepare(key: cacheKey, body: body, resources: resources.resources, isSpeculative: true)
                }
                return
            }
        } catch { /* Selection retries required content in the foreground lane. */ }
    }
}

struct MessagePrefetchModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    @State private var controller = MessagePrefetchController()

    private var plan: MessagePrefetchPlan {
        guard app.destination == .mail,
              mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID else {
            return MessagePrefetchPlan(keys: [], accounts: [], selected: [])
        }
        return MessagePrefetchPlan(
            keys: MessagePrefetchPlan.candidates(rows: mailbox.listItems.map(\.id), selected: mailbox.selectedListRowIDs),
            accounts: mailbox.accounts.map(ObjectIdentifier.init),
            selected: mailbox.selectedListRowIDs
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { MessageWebViewWarmup.start() }
            .onChange(of: plan, initial: true) { _, plan in
                controller.update(keys: plan.keys, accounts: plan.accounts.isEmpty ? [] : mailbox.accounts, mailbox: mailbox)
            }
            .onDisappear { controller.stop() }
    }
}
