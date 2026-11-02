import MailStore
import SwiftUI

struct ReaderSessionID: Hashable, Identifiable {
    let key: ThreadKey
    let messageID: String?
    let owner: ObjectIdentifier
    var id: Self { self }

    /// Presentation stays independent of cache recency, so switching between
    /// retained sessions does not move their existing native subtrees.
    func precedesInPresentation(_ other: Self) -> Bool {
        if key.accountID != other.key.accountID { return key.accountID < other.key.accountID }
        if key.threadID != other.key.threadID { return key.threadID < other.key.threadID }
        switch (messageID, other.messageID) {
        case (nil, .some): return true
        case (.some, nil): return false
        case (let lhs?, let rhs?) where lhs != rhs: return lhs < rhs
        default: return owner < other.owner
        }
    }
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
    @ObservationIgnored private(set) var sessions: [ReaderSessionID] = []
    private var membershipRevision: UInt64 = 0
    private var costs: [ReaderSessionID: Int] = [:]
    private var lastUse: [ReaderSessionID: UInt64] = [:]
    private var selected: ReaderSessionID?
    private var isVisible = false
    private var discardedSources: Set<ReaderSessionID> = []
    #if DEBUG || TERN_PERFORMANCE
    /// Shares the existing state owner's lifetime without adding observation.
    let layoutAuditOwnerToken = ReaderLayoutDiagnostics.allocateToken()
    #endif
    let countLimit = 3
    let byteLimit = 8 * 1_024 * 1_024

    init() { Self.stores.append(WeakStore(self)) }

    func presenting(_ selected: ReaderSessionID) -> [ReaderSessionID] {
        _ = membershipRevision
        // Predict activation before its onChange runs. Hidden-window retention
        // uses this MRU suffix even when the selected session is already cached.
        return Array((sessions.filter { $0 != selected } + [selected]).suffix(countLimit))
    }

    func activate(_ id: ReaderSessionID) {
        let previousMembership = Set(sessions)
        selected = id
        if isVisible, discardedSources.contains(id) { discardedSources.remove(id) }
        Self.clock &+= 1
        lastUse[id] = Self.clock
        sessions.removeAll { $0 == id }
        sessions.append(id)
        trim(keeping: id)
        publishMembershipChange(from: previousMembership)
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
        if visible, discardedSources.contains(selected) { discardedSources.remove(selected) }
        trim(keeping: selected)
    }

    private func trim(keeping selected: ReaderSessionID) {
        self.selected = selected
        while sessions.count > countLimit {
            guard let index = sessions.firstIndex(where: { $0 != selected }) else { break }
            let removed = sessions.remove(at: index)
            costs[removed] = nil; lastUse[removed] = nil
            if discardedSources.contains(removed) { discardedSources.remove(removed) }
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
        let previousMembership = Set(sessions)
        sessions = sessions.filter { $0 == selected }
        costs = costs.filter { $0.key == selected }
        lastUse = lastUse.filter { $0.key == selected }
        let retainedSources = discardedSources.intersection([selected])
        if retainedSources != discardedSources { discardedSources = retainedSources }
        publishMembershipChange(from: previousMembership)
    }

    private func publishMembershipChange(from previous: Set<ReaderSessionID>) {
        if Set(sessions) != previous { membershipRevision &+= 1 }
    }
}

struct ReaderSessionContainer: View {
    let key: ThreadKey
    let messageID: String?
    let mailbox: MailboxModel
    let isActive: Bool
    var reportsNavigation = true
    var onDetailChange: ((ThreadDetail) -> Void)? = nil
    @State private var store = ReaderSessionStore()
    @State private var isWindowVisible = false
    @State private var allowsHiddenBodyRetention = true

    private var selection: ReaderSessionID {
        ReaderSessionID(key: key, messageID: messageID,
                        owner: mailbox.account(id: key.accountID).map(ObjectIdentifier.init) ?? ObjectIdentifier(mailbox))
    }

    private var windowVisibility: ReaderWindowVisibility {
        var observer = ReaderWindowVisibility(didChange: { isWindowVisible = $0 })
        #if DEBUG || TERN_PERFORMANCE
        if ReaderLayoutDiagnostics.shared != nil {
            let owner = store
            let visibility = $isWindowVisible
            // Sample inside native updates, without making the visibility
            // scalar an additional representable input during resizing.
            observer.auditSnapshot = { [weak owner, visibility] in
                (ownerToken: owner?.layoutAuditOwnerToken ?? 0, ownerVisible: visibility.wrappedValue)
            }
        }
        #endif
        return observer
    }

    var body: some View {
        let selected = selection
        let recentSessions = store.presenting(selected)
        let displaySessions = recentSessions.sorted { $0.precedesInPresentation($1) }
        let visible = isActive && isWindowVisible
        ZStack {
            ForEach(displaySessions) { session in
                let active = visible && session == selected
                ThreadView(key: session.key, mailbox: mailbox, selectedMessageID: session.messageID,
                           isReaderActive: active,
                           retainsHiddenBody: !active && allowsHiddenBodyRetention && store.retainsSource(for: session)
                               && (visible || recentSessions.suffix(2).contains(session)),
                           retainsSourceSnapshot: store.retainsSource(for: session),
                           interaction: active && reportsNavigation ? ReaderInteraction(body: NavigationPerformance.shared.currentGeneration(for: .reader),
                               header: NavigationPerformance.shared.currentGeneration(for: .readerHeader)) : nil,
                           onDetailChange: { detail in
                               store.record(detail, for: session, selected: selected)
                               if session == selected { onDetailChange?(detail) }
                           })
                    .opacity(session == selected ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .zIndex(session == selected ? 1 : 0)
            }
        }
        .background(windowVisibility)
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
