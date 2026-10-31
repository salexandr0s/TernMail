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
    let countLimit = 3
    let byteLimit = 8 * 1_024 * 1_024

    init() { Self.stores.append(WeakStore(self)) }

    func presenting(_ selected: ReaderSessionID) -> [ReaderSessionID] {
        if sessions.contains(selected) { return sessions }
        return Array((sessions + [selected]).suffix(countLimit))
    }

    func activate(_ id: ReaderSessionID) {
        selected = id
        Self.clock &+= 1
        lastUse[id] = Self.clock
        sessions.removeAll { $0 == id }
        sessions.append(id)
        trim(keeping: id)
    }

    func record(_ detail: ThreadDetail, for id: ReaderSessionID, selected: ReaderSessionID) {
        var bytes = 0
        for message in detail.messages {
            let htmlBytes = message.body?.html?.utf8.count ?? 0
            let textBytes = message.body?.plainText?.utf8.count ?? 0
            bytes += (htmlBytes + textBytes) * 2 + 2_048
        }
        costs[id] = bytes
        trim(keeping: selected)
    }

    func trim(keeping selected: ReaderSessionID) {
        self.selected = selected
        while sessions.count > countLimit {
            guard let index = sessions.firstIndex(where: { $0 != selected }) else { break }
            let removed = sessions.remove(at: index)
            costs[removed] = nil; lastUse[removed] = nil
        }
        Self.stores.removeAll { $0.value == nil }
        // Only the currently displayed source is working memory. All hidden
        // source snapshots across every window share this eight-MiB budget.
        while true {
            let hidden = Self.stores.compactMap(\.value).flatMap { store in
                store.sessions.filter { $0 != store.selected }.map { (store: store, id: $0, bytes: store.costs[$0] ?? 0, used: store.lastUse[$0] ?? 0) }
            }
            guard hidden.reduce(0, { $0 + $1.bytes }) > byteLimit,
                  let oldest = hidden.min(by: { $0.used < $1.used }) else { break }
            oldest.store.sessions.removeAll { $0 == oldest.id }
            oldest.store.costs[oldest.id] = nil; oldest.store.lastUse[oldest.id] = nil
        }
    }

    func releaseHidden(keeping selected: ReaderSessionID) {
        sessions = sessions.filter { $0 == selected }
        costs = costs.filter { $0.key == selected }
        lastUse = lastUse.filter { $0.key == selected }
    }
}

struct ReaderSessionContainer: View {
    let key: ThreadKey
    let messageID: String?
    let mailbox: MailboxModel
    let isActive: Bool
    @State private var store = ReaderSessionStore()

    private var selection: ReaderSessionID {
        ReaderSessionID(key: key, messageID: messageID,
                        owner: mailbox.account(id: key.accountID).map(ObjectIdentifier.init) ?? ObjectIdentifier(mailbox))
    }

    var body: some View {
        let selected = selection
        let sessions = store.presenting(selected)
        ZStack {
            ForEach(sessions) { session in
                let active = isActive && session == selected
                ThreadView(key: session.key, mailbox: mailbox, selectedMessageID: session.messageID,
                           isReaderActive: active, retainsHiddenBody: !active && (isActive || sessions.suffix(2).contains(session)),
                           interaction: active ? ReaderInteraction(body: NavigationPerformance.shared.currentGeneration(for: .reader),
                               header: NavigationPerformance.shared.currentGeneration(for: .readerHeader)) : nil,
                           onDetailChange: { store.record($0, for: session, selected: selected) })
                    .opacity(session == selected ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .zIndex(session == selected ? 1 : 0)
            }
        }
        .onChange(of: selected, initial: true) { _, id in store.activate(id) }
        .onChange(of: ReaderCacheLifecycle.shared.pressureRevision) { _, _ in store.releaseHidden(keeping: selected) }
    }
}
