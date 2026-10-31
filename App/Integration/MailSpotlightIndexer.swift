import CoreSpotlight
import Foundation
import MailStore
import MessageContent
import UniformTypeIdentifiers

extension UserDefaults {
    /// Settings' Show Mail in Spotlight. The property shares the key's name,
    /// so observing it sees every change, including one from another process.
    @objc dynamic var showsMailInSpotlight: Bool { bool(forKey: MailSpotlightIndexer.enabledKey) }
}

/// Lists cached conversations in Spotlight while the user allows it. Each
/// conversation is one item: its subject, Gmail's snippet, the latest
/// sender's display name and the last message date. Bodies and addresses
/// are never indexed. Passes run one at a time, and their cache reads and
/// index calls run off the main actor.
@MainActor
final class MailSpotlightIndexer {
    /// The `UserDefaults` key behind the Settings toggle. Off by default.
    nonisolated static let enabledKey = "showsMailInSpotlight"
    /// Conversations listed per account: the Inbox first, then the most recent.
    nonisolated static let accountLimit = 2_000
    nonisolated private static let batchSize = 500

    /// The fields one conversation's item carries.
    struct Conversation: Sendable, Equatable {
        var accountID: String
        var threadID: String
        var subject: String
        var snippet: String
        /// The latest sender's display name, never an address.
        var senderName: String?
        var lastDate: Date
    }

    private weak var app: AppModel?
    private let defaults: UserDefaults
    private var observation: NSKeyValueObservation?
    private var isEnabled: Bool
    /// What each account's last finished pass indexed: thread ID to a hash of its fields.
    private var indexed: [String: [String: Int]] = [:]
    /// Accounts with a pass waiting, so a burst of syncs runs one pass each.
    private var queued: Set<String> = []
    /// Bumped by a rebuild or a removal, which drops the passes queued before it.
    private var generation = 0
    private var tail: Task<Void, Never>?

    init(app: AppModel, defaults: UserDefaults = .standard) {
        self.app = app
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        observation = defaults.observe(\.showsMailInSpotlight) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.preferenceChanged() }
        }
    }

    /// Rebuilds the index from the open mailbox's cache. Items an earlier
    /// launch left behind go first, since the cache may have changed since.
    func start() {
        guard isEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        generation += 1
        queued = []
        let current = generation
        enqueue { [weak self] in
            guard let self, current == generation, isEnabled else { return }
            indexed = [:]
            do { try await Self.removeEverything() } catch { return }
            for accountID in app?.mailbox?.accounts.map(\.account.id) ?? [] {
                guard current == generation, isEnabled else { return }
                await update(accountID)
            }
        }
    }

    /// A sync finished for `accountID`: index what changed and remove what left.
    func mailSynced(accountID: String) {
        guard isEnabled, queued.insert(accountID).inserted else { return }
        let current = generation
        enqueue { [weak self] in
            guard let self, current == generation else { return }
            queued.remove(accountID)
            guard isEnabled else { return }
            await update(accountID)
        }
    }

    /// Removes the accounts' items, after sign-out or when their cached mail is deleted.
    func remove(accountIDs: Set<String>) {
        guard isEnabled, !accountIDs.isEmpty else { return }
        queued.subtract(accountIDs)
        enqueue { [weak self] in
            for accountID in accountIDs { self?.indexed.removeValue(forKey: accountID) }
            try? await Self.remove(domains: Array(accountIDs))
        }
    }

    /// Removes every item, as a cache reset or signing out of every account needs.
    func removeAll() {
        guard isEnabled else { return }
        clear()
    }

    private func preferenceChanged() {
        let enabled = defaults.bool(forKey: Self.enabledKey)
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled { start() } else { clear() }
    }

    private func clear() {
        generation += 1
        queued = []
        enqueue { [weak self] in
            self?.indexed = [:]
            try? await Self.removeEverything()
        }
    }

    /// Runs `work` after every pass queued before it.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    private func update(_ accountID: String) async {
        guard let cache = app?.cache, app?.mailbox?.account(id: accountID) != nil else { return }
        let known = indexed[accountID] ?? [:]
        do {
            indexed[accountID] = try await Self.reindex(accountID: accountID, cache: cache, known: known)
        } catch {
            // The next sync compares against the last finished pass again.
        }
    }

    // MARK: Off the main actor

    /// Indexes the account's conversations that differ from `known` and
    /// removes the ones no longer listed. Returns what the account now has.
    nonisolated private static func reindex(
        accountID: String, cache: MailCache, known: [String: Int]
    ) async throws -> [String: Int] {
        let threads = try await listedThreads(accountID: accountID, cache: cache)
        var current: [String: Int] = [:]
        for thread in threads { current[thread.id] = fingerprint(thread) }
        let changed = threads.filter { known[$0.id] != current[$0.id] }
        let senders = try await latestSenders(of: changed, accountID: accountID, cache: cache)
        let items = changed.compactMap { thread in
            item(for: Conversation(
                accountID: accountID, threadID: thread.id, subject: thread.subject, snippet: thread.snippet,
                senderName: senders[thread.id], lastDate: thread.lastDate
            ))
        }
        let index = CSSearchableIndex.default()
        for start in stride(from: 0, to: items.count, by: batchSize) {
            try await index.indexSearchableItems(Array(items[start..<min(start + batchSize, items.count)]))
        }
        // Moved to Trash or Spam, deleted, or pushed past the limit.
        let gone = known.keys.filter { current[$0] == nil }
            .compactMap { MailLink(accountID: accountID, threadID: $0).ternURL?.absoluteString }
        if !gone.isEmpty { try await index.deleteSearchableItems(withIdentifiers: gone) }
        return current
    }

    /// The Inbox, then the most recent conversations outside Trash and Spam,
    /// up to `accountLimit`.
    nonisolated private static func listedThreads(accountID: String, cache: MailCache) async throws -> [ThreadRecord] {
        var threads: [ThreadRecord] = []
        var seen = Set<String>()
        for labelID in [SystemLabel.inbox, SystemLabel.allMail] where threads.count < accountLimit {
            for try await page in cache.threads(accountID: accountID, labelID: labelID, limit: accountLimit) {
                for thread in page where threads.count < accountLimit && seen.insert(thread.id).inserted {
                    threads.append(thread)
                }
                break
            }
        }
        return threads
    }

    /// The display name of each conversation's latest sender, when it has one.
    nonisolated private static func latestSenders(
        of threads: [ThreadRecord], accountID: String, cache: MailCache
    ) async throws -> [String: String] {
        guard !threads.isEmpty else { return [:] }
        return try await cache.read { tx in
            var names: [String: String] = [:]
            for thread in threads {
                let messages = try tx.messages(threadID: thread.id, accountID: accountID)
                // A draft on its way out isn't part of the listed conversation yet.
                let latest = messages.last { $0.date <= thread.lastDate } ?? messages.last
                if let name = latest.flatMap({ senderName($0.sender) }) { names[thread.id] = name }
            }
            return names
        }
    }

    nonisolated private static func fingerprint(_ thread: ThreadRecord) -> Int {
        var hasher = Hasher()
        hasher.combine(thread.subject)
        hasher.combine(thread.snippet)
        hasher.combine(thread.participants)
        hasher.combine(thread.lastDate)
        hasher.combine(thread.messageCount)
        return hasher.finalize()
    }

    nonisolated private static func removeEverything() async throws {
        try await CSSearchableIndex.default().deleteAllSearchableItems()
    }

    nonisolated private static func remove(domains: [String]) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: domains)
    }

    // MARK: Items

    /// The item for one conversation, identified by its `tern://` link and
    /// grouped by account. Nil when the link can't be built.
    nonisolated static func item(for conversation: Conversation) -> CSSearchableItem? {
        guard let link = MailLink(accountID: conversation.accountID, threadID: conversation.threadID).ternURL else {
            return nil
        }
        let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
        attributes.title = conversation.subject.isEmpty ? "No Subject" : conversation.subject
        attributes.contentDescription = conversation.snippet.isEmpty ? nil : conversation.snippet
        attributes.authorNames = conversation.senderName.map { [$0] }
        attributes.contentModificationDate = conversation.lastDate
        let item = CSSearchableItem(
            uniqueIdentifier: link.absoluteString, domainIdentifier: conversation.accountID, attributeSet: attributes
        )
        // Passes and the setting remove items, so none should expire on its own.
        item.expirationDate = .distantFuture
        return item
    }

    /// The display name in a From header. Nil when there is none, or when the
    /// name is itself an address.
    nonisolated static func senderName(_ header: String) -> String? {
        guard let name = EmailAddress.parseList(header).first?.name, !name.contains("@") else { return nil }
        return name
    }
}
