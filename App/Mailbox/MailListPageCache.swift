import Dispatch
import Diagnostics
import Foundation
import MailStore

/// A complete database page and its body-free presentation, prepared away
/// from SwiftUI. Its configuration excludes the publication's data revision.
struct PreparedMailListPage: Sendable {
    let page: MailListPage
    let rows: [MessageListItem]
    let configuration: MessageListProjection.Key
    let cost: Int
}

/// One serial preparation lane bounds work when several observed mailboxes
/// change together. Canceled subscriptions never enqueue the next page.
actor MailListPreparation {
    static let shared = MailListPreparation()

    func prepare(_ page: MailListPage, input: MessageListProjection.Input,
                 configuration: MessageListProjection.Key, reusing previous: PreparedMailListPage? = nil) throws -> PreparedMailListPage {
        try Task.checkCancellation()
        let span = TernSignposts.begin(.mailListProjection)
        let rows = MessageListProjection.prepare(input,
            reusing: previous?.configuration == configuration ? previous?.rows ?? [] : [])
        if Task.isCancelled {
            TernSignposts.cancel(span)
            throw CancellationError()
        }
        TernSignposts.end(span)
        // Include array/record overhead and the strings retained by both the
        // raw page and presentation. Shared COW storage makes this conservative.
        var cost = 0
        for thread in page.threads {
            cost += 512
            cost += thread.subject.utf8.count
            cost += thread.snippet.utf8.count
            cost += thread.participants.utf8.count
        }
        for entry in page.entries {
            let message = entry.message
            cost += 768
            cost += message.subject.utf8.count
            cost += message.snippet.utf8.count
            cost += message.sender.utf8.count
            cost += message.recipients.utf8.count
            cost += message.cc?.utf8.count ?? 0
            for attachment in entry.attachments {
                cost += 256 + attachment.filename.utf8.count
            }
        }
        return PreparedMailListPage(page: page, rows: rows, configuration: configuration, cost: cost)
    }
}

/// App-wide accounting for retained list pages across windows. Calendar owns
/// 12 MiB and readers own 8 MiB of the shared 32 MiB snapshot allowance.
@MainActor
private final class MailListSnapshotBudget {
    static let shared = MailListSnapshotBudget()
    private let limit = 12 * 1_024 * 1_024
    private var entries: [UUID: (cost: Int, stamp: UInt64, evict: () -> Void)] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private let pressure: any DispatchSourceMemoryPressure

    private init() {
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor in self?.evictAll() }
        }
        pressure.resume()
    }

    private func evictAll() {
        let callbacks = entries.values.map(\.evict)
        entries.removeAll()
        bytes = 0
        callbacks.forEach { $0() }
    }

    func claim(_ id: UUID, bytes cost: Int, evict: @escaping () -> Void) {
        release(id)
        clock &+= 1
        entries[id] = (cost, clock, evict)
        bytes += cost
        while bytes > limit, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) {
            release(oldest.key)
            oldest.value.evict()
        }
    }

    func touch(_ id: UUID) {
        guard var entry = entries[id] else { return }
        clock &+= 1
        entry.stamp = clock
        entries[id] = entry
    }

    func release(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) { bytes -= entry.cost }
    }

    func holds(_ id: UUID) -> Bool { entries[id] != nil }
}

/// Recent mailboxes remain observed, so returning to one cannot replay a
/// snapshot from before its last delivered pending-action or sync update.
@MainActor
final class MailListPageCache {
    struct Key: Hashable {
        let accountIDs: [String]
        let labelID: String
        let limit: Int
        var retainedReadRows: Set<MailListRowID> = []

        /// True for the same mailbox and visit at another page size.
        func isOtherLimit(of other: Key) -> Bool {
            limit != other.limit && accountIDs == other.accountIDs && labelID == other.labelID
                && retainedReadRows == other.retainedReadRows
        }
    }

    typealias Configuration = @MainActor (MailListPage) -> (MessageListProjection.Input, MessageListProjection.Key)

    private final class Entry {
        let id = UUID()
        let cache: MailCache
        var configuration: Configuration
        var value: PreparedMailListPage?
        /// The last prepared page. The next one reuses its unchanged rows.
        /// Invalidation leaves it alone, and it is never replayed.
        var reuseBase: PreparedMailListPage?
        var task: Task<Void, Never>?
        var canReplay = true
        /// True until the first page is prepared. The read a new activation
        /// would start is then already running.
        var isLoading = true

        init(cache: MailCache, configuration: @escaping Configuration) {
            self.cache = cache
            self.configuration = configuration
        }
    }

    private var entries: [Key: Entry] = [:]
    private var recent: [Key] = []
    private var active: Key?
    private var deliver: ((PreparedMailListPage, Bool) -> Void)?
    private var fail: (() -> Void)?
    private let capacity = 4

    func activate(_ key: Key, cache: MailCache, configuration: @escaping Configuration,
                  onValue: @escaping @MainActor (PreparedMailListPage, Bool) -> Void,
                  onError: @escaping @MainActor () -> Void) {
        // Loading more of a mailbox changes its key. The larger page reuses
        // the rows its smaller page already prepared.
        let seed = entries[key] == nil ? reuseSeed(for: key) : nil
        if active != key { leaveActive() }
        active = key
        deliver = onValue
        fail = onError
        recent.removeAll { $0 == key }
        recent.append(key)
        if let entry = entries[key] {
            entry.configuration = configuration
            if entry.canReplay {
                if let value = entry.value {
                    MailListSnapshotBudget.shared.touch(entry.id)
                    onValue(value, true)
                    return
                }
                // The first read for this key is still running and nothing has
                // invalidated it. Its page goes to the callbacks set above, so
                // starting the read again would only deliver it later.
                if entry.isLoading { return }
            }
            // An evicted or explicitly invalidated value must get a fresh first
            // observation value even if no subsequent write changes the mailbox.
            subscribe(entry, to: key)
            return
        }
        let entry = Entry(cache: cache, configuration: configuration)
        entry.reuseBase = seed
        entries[key] = entry
        while recent.count > capacity { remove(recent.removeFirst()) }
        subscribe(entry, to: key)
    }

    /// Starts the entry's observation over. Its first page is read after this call.
    private func subscribe(_ entry: Entry, to key: Key) {
        entry.task?.cancel()
        entry.canReplay = true
        entry.isLoading = true
        entry.value = nil
        let retained = Dictionary(grouping: key.retainedReadRows, by: \.accountID)
            .mapValues { Set($0.compactMap(\.messageID)) }
        let stream = entry.cache.listPage(.mailbox(accountIDs: key.accountIDs, labelID: key.labelID, limit: key.limit,
            retainingReadMessageIDs: retained))
        entry.task = Task { [weak self, weak entry] in
            do {
                for try await page in stream {
                    guard !Task.isCancelled, let self, let entry, entries[key] === entry else { return }
                    let (input, keyConfiguration) = entry.configuration(page)
                    let prepared = try await MailListPreparation.shared.prepare(page, input: input,
                        configuration: keyConfiguration, reusing: entry.reuseBase)
                    guard !Task.isCancelled, entries[key] === entry else { return }
                    store(prepared, in: entry, for: key)
                    if active == key { deliver?(prepared, false) }
                }
            } catch {
                guard !Task.isCancelled, let self, let entry, entries[key] === entry else { return }
                let wasActive = active == key
                remove(key)
                if wasActive { fail?() }
            }
        }
    }

    private func store(_ prepared: PreparedMailListPage, in entry: Entry, for key: Key) {
        let isFirstPage = entry.isLoading
        entry.isLoading = false
        entry.reuseBase = prepared
        if entry.canReplay { entry.value = prepared }
        MailListSnapshotBudget.shared.claim(entry.id, bytes: prepared.cost) { [weak self, weak entry] in
            guard let entry else { return }
            entry.value = nil
            // The selected mailbox's model holds these rows too, so its reuse base stays.
            if let self, let active = self.active, self.entries[active] === entry { return }
            entry.reuseBase = nil
        }
        if isFirstPage { removePagesReplaced(by: key) }
    }

    /// The largest other page of the same mailbox that has prepared rows.
    private func reuseSeed(for key: Key) -> PreparedMailListPage? {
        entries.filter { $0.key.isOtherLimit(of: key) && $0.value.reuseBase != nil }
            .max { $0.key.limit < $1.key.limit }?.value.reuseBase
    }

    /// A larger page replaces the pages it grew from. The smallest stays,
    /// because selecting the mailbox again asks for its first page.
    private func removePagesReplaced(by key: Key) {
        let smaller = entries.keys.filter { $0.limit < key.limit && $0.isOtherLimit(of: key) }
        guard let first = smaller.map(\.limit).min() else { return }
        for other in smaller where other.limit != first { remove(other) }
    }

    /// The selected mailbox's model holds the rows of its reuse base. Once the
    /// mailbox is left, that base is counted against the budget or dropped.
    private func leaveActive() {
        guard let active, let entry = entries[active] else { return }
        // An Unread visit's key lists the rows read during it. Nothing asks
        // for that key again once the visit moves on.
        guard active.retainedReadRows.isEmpty else { return remove(active) }
        if !MailListSnapshotBudget.shared.holds(entry.id) { entry.reuseBase = nil }
        // A change made while this mailbox was selected left it stale.
        if !entry.canReplay { scheduleRefresh() }
    }

    func deactivate() {
        leaveActive()
        active = nil
        deliver = nil
        fail = nil
    }

    /// Call before and after a local change. No page read before the latest
    /// call is replayed. Every subscription continues, and the mailboxes that
    /// are not selected are read again once the change settles, so returning
    /// to one finds a page read after the write.
    func invalidateRetained() {
        for entry in entries.values {
            entry.canReplay = false
            entry.value = nil
        }
        scheduleRefresh()
    }

    private var refresh: Task<Void, Never>?
    /// Long enough for the calls before and after one change to share a read.
    private static let refreshDelay = Duration.milliseconds(100)

    /// A subscription that began before a change can still deliver a page
    /// read before it, so each stale entry is subscribed again. A later
    /// change restarts the wait and marks those entries stale once more.
    private func scheduleRefresh() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            try? await Task.sleep(for: MailListPageCache.refreshDelay)
            guard !Task.isCancelled, let self else { return }
            for (key, entry) in entries where key != active && !entry.canReplay { subscribe(entry, to: key) }
        }
    }

    /// The next activation reads a fresh page, including after a Gmail
    /// response that leaves the database unchanged.
    func invalidateActive() {
        if let active, let entry = entries[active] {
            // Even a pre-mutation read already being prepared must not restore
            // an older replay value after invalidation. A revisit resubscribes.
            // The reuse base stays, so the budget keeps counting the page.
            entry.canReplay = false
            entry.value = nil
        }
    }

    func stop() {
        deactivate()
        refresh?.cancel()
        refresh = nil
        for key in Array(entries.keys) { remove(key) }
    }

    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.task?.cancel()
        MailListSnapshotBudget.shared.release(entry.id)
        recent.removeAll { $0 == key }
    }
}
