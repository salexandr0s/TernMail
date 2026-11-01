import MailStore
import SwiftUI

struct ReaderSessionID: Hashable, Identifiable {
    let key: ThreadKey
    let messageID: String?
    let owner: ObjectIdentifier
    var id: Self { self }
}

struct ReaderInteraction {
    let body: UInt64?
    let header: UInt64?
}

/// Three lightweight sessions, with a byte bound on retained source snapshots.
@MainActor @Observable
final class ReaderSessionStore {
    private final class WeakStore { weak var value: ReaderSessionStore?; init(_ value: ReaderSessionStore) { self.value = value } }
    private static var stores: [WeakStore] = []
    private static var clock: UInt64 = 0
    private(set) var sessions: [ReaderSessionID] = []
    private var costs: [ReaderSessionID: Int] = [:]
    private var lastUse: [ReaderSessionID: UInt64] = [:]
    private var selected: ReaderSessionID?
    private var isVisible = false
    private var discardedSources: Set<ReaderSessionID> = []
    let countLimit = 3
    let byteLimit = 8 * 1_024 * 1_024

    init() { Self.stores.append(WeakStore(self)) }

    func presenting(_ selected: ReaderSessionID) -> [ReaderSessionID] {
        if sessions.contains(selected) { return sessions }
        return Array((sessions + [selected]).suffix(countLimit))
    }

    func activate(_ id: ReaderSessionID) {
        selected = id
        if isVisible { discardedSources.remove(id) }
        Self.clock &+= 1
        lastUse[id] = Self.clock
        sessions.removeAll { $0 == id }
        sessions.append(id)
        trim(keeping: id)
    }

    func record(_ detail: ThreadDetail, for id: ReaderSessionID, selected: ReaderSessionID) {
        if discardedSources.contains(id) {
            guard isVisible, id == selected else { return }
            discardedSources.remove(id)
        }
        var bytes = 0
        for message in detail.messages {
            let htmlBytes = message.body?.html?.utf8.count ?? 0
            let textBytes = message.body?.plainText?.utf8.count ?? 0
            // Include independent Find and calendar extraction strings even if
            // their prepared-cache entries have already been evicted.
            bytes += (htmlBytes + textBytes) * 3 + 2_048
        }
        costs[id] = bytes
        trim(keeping: selected)
    }

    func retainsSource(for id: ReaderSessionID) -> Bool { !discardedSources.contains(id) }

    func setVisible(_ visible: Bool, selected: ReaderSessionID) {
        isVisible = visible
        if visible { discardedSources.remove(selected) }
        trim(keeping: selected)
    }

    func trim(keeping selected: ReaderSessionID) {
        self.selected = selected
        while sessions.count > countLimit {
            guard let index = sessions.firstIndex(where: { $0 != selected }) else { break }
            let removed = sessions.remove(at: index)
            costs[removed] = nil; lastUse[removed] = nil
            discardedSources.remove(removed)
        }
        Self.stores.removeAll { $0.value == nil }
        // Only the currently displayed source is working memory. All hidden
        // source snapshots across every window share this eight-MiB budget.
        while true {
            let hidden = Self.stores.compactMap(\.value).flatMap { store in
                store.sessions.filter { !(store.isVisible && $0 == store.selected)
                    && !store.discardedSources.contains($0) && (store.costs[$0] ?? 0) > 0 }
                    .map { (store: store, id: $0, bytes: store.costs[$0] ?? 0, used: store.lastUse[$0] ?? 0) }
            }
            guard hidden.reduce(0, { $0 + $1.bytes }) > byteLimit,
                  let oldest = hidden.min(by: { $0.used < $1.used }) else { break }
            oldest.store.discardedSources.insert(oldest.id)
        }
    }

    func releaseHidden(keeping selected: ReaderSessionID) {
        sessions = sessions.filter { $0 == selected }
        costs = costs.filter { $0.key == selected }
        lastUse = lastUse.filter { $0.key == selected }
        discardedSources = discardedSources.intersection([selected])
    }
}

struct ReaderSessionContainer: View {
    let key: ThreadKey
    let messageID: String?
    let mailbox: MailboxModel
    let isActive: Bool
    @State private var store = ReaderSessionStore()
    @State private var isWindowVisible = false
    @State private var allowsHiddenBodyRetention = true

    private var selection: ReaderSessionID {
        ReaderSessionID(key: key, messageID: messageID,
                        owner: mailbox.account(id: key.accountID).map(ObjectIdentifier.init) ?? ObjectIdentifier(mailbox))
    }

    var body: some View {
        let selected = selection
        let sessions = store.presenting(selected)
        let visible = isActive && isWindowVisible
        ZStack {
            ForEach(sessions) { session in
                let active = visible && session == selected
                ThreadView(key: session.key, mailbox: mailbox, selectedMessageID: session.messageID,
                           isReaderActive: active,
                           retainsHiddenBody: !active && allowsHiddenBodyRetention && store.retainsSource(for: session)
                               && (visible || sessions.suffix(2).contains(session)),
                           retainsSourceSnapshot: store.retainsSource(for: session),
                           interaction: active ? ReaderInteraction(body: NavigationPerformance.shared.currentGeneration(for: .reader),
                               header: NavigationPerformance.shared.currentGeneration(for: .readerHeader)) : nil,
                           onDetailChange: { store.record($0, for: session, selected: selected) })
                    .opacity(session == selected ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .zIndex(session == selected ? 1 : 0)
            }
        }
        .background(ReaderWindowVisibility { isWindowVisible = $0 })
        .onChange(of: selected, initial: true) { _, id in
            store.activate(id)
            if visible { allowsHiddenBodyRetention = true }
        }
        .onChange(of: visible, initial: true) { _, visible in
            store.setVisible(visible, selected: selected)
            if visible { allowsHiddenBodyRetention = true }
        }
        .onChange(of: ReaderCacheLifecycle.shared.pressureRevision) { _, _ in
            allowsHiddenBodyRetention = false
            store.releaseHidden(keeping: selected)
        }
    }
}
