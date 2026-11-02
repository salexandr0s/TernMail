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
}

/// Recent mailboxes remain observed, so returning to one cannot replay a
/// snapshot from before its last delivered pending-action or sync update.
@MainActor
final class MailListPageCache {
    struct Key: Hashable {
        let accountIDs: [String]
        let labelID: String
        let limit: Int
    }

    private final class Entry {
        let id = UUID()
        var value: PreparedMailListPage?
        var task: Task<Void, Never>?
        var canReplay = true
    }

    private var entries: [Key: Entry] = [:]
    private var recent: [Key] = []
    private var active: Key?
    private var deliver: ((PreparedMailListPage, Bool) -> Void)?
    private let capacity = 4

    func activate(_ key: Key, cache: MailCache,
                  configuration: @escaping @MainActor (MailListPage) -> (MessageListProjection.Input, MessageListProjection.Key),
                  onValue: @escaping @MainActor (PreparedMailListPage, Bool) -> Void,
                  onError: @escaping @MainActor () -> Void) {
        active = key
        deliver = onValue
        recent.removeAll { $0 == key }
        recent.append(key)
        if let entry = entries[key], entry.canReplay, let value = entry.value {
            MailListSnapshotBudget.shared.touch(entry.id)
            onValue(value, true)
            return
        }
        // An evicted or explicitly invalidated value must get a fresh first
        // observation value even if no subsequent write changes the mailbox.
        if entries[key] != nil { remove(key); recent.append(key) }
        let entry = Entry()
        entries[key] = entry
        while recent.count > capacity { remove(recent.removeFirst()) }
        let stream = cache.listPage(accountIDs: key.accountIDs, labelID: key.labelID, limit: key.limit)
        entry.task = Task { [weak self, weak entry] in
            do {
                for try await page in stream {
                    guard !Task.isCancelled, let self, let entry, entries[key] === entry else { return }
                    let (input, keyConfiguration) = configuration(page)
                    let prepared = try await MailListPreparation.shared.prepare(page, input: input,
                        configuration: keyConfiguration, reusing: entry.value)
                    guard !Task.isCancelled, entries[key] === entry else { return }
                    if entry.canReplay {
                        entry.value = prepared
                        MailListSnapshotBudget.shared.claim(entry.id, bytes: prepared.cost) { [weak entry] in entry?.value = nil }
                    }
                    if active == key { deliver?(prepared, false) }
                }
            } catch {
                guard !Task.isCancelled, let self, let entry, entries[key] === entry else { return }
                remove(key)
                if active == key { onError() }
            }
        }
    }

    func deactivate() { active = nil; deliver = nil }

    /// Before a local mutation, drop retained pages. The selected subscription
    /// continues, but revisiting another destination must read after the write.
    func invalidateRetained() {
        for key in Array(entries.keys) where key != active { remove(key) }
        if let active, let entry = entries[active] {
            // Even a pre-mutation read already being prepared must not restore
            // an older replay value after invalidation. A revisit resubscribes.
            entry.canReplay = false
            entry.value = nil
            MailListSnapshotBudget.shared.release(entry.id)
        }
    }

    func stop() {
        deactivate()
        for key in Array(entries.keys) { remove(key) }
    }

    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.task?.cancel()
        MailListSnapshotBudget.shared.release(entry.id)
        recent.removeAll { $0 == key }
    }
}
