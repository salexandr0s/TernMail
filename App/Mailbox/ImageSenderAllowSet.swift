import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation

/// The senders one account lets load remote images, kept in memory so the
/// reader knows a message's permission when it first lays out. The saved
/// list stays the authority: the set is filled only from it, and changed
/// only after a save to it has succeeded.
@MainActor @Observable
final class ImageSenderAllowSet {
    private enum State {
        case unread
        case loaded(Set<String>)
        /// The saved list couldn't be read. Images stay blocked, and the next reader asks again.
        case unavailable
    }

    /// The one account whose saved list this set reads.
    let accountID: String
    private var state = State.unread
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(accountID: String) { self.accountID = accountID }

    /// False until the saved list has been read. A reader holds its first
    /// render until then, so it never shows mail before it knows the permission.
    var isKnown: Bool {
        if case .unread = state { return false }
        return true
    }

    /// The remembered grant for `identity`: the identity itself when it is
    /// this account's and its verified sender is on the list, otherwise nil.
    func remembered(_ identity: SenderImageIdentity) -> SenderImageIdentity? {
        guard identity.accountID == accountID, let address = identity.address,
              case .loaded(let senders) = state, senders.contains(address) else { return nil }
        return identity
    }

    /// Reads the saved list once. Later calls return at once, and a failed read is tried again.
    func load(from store: AccountStore?) async {
        if case .loaded = state { return }
        if let loading { return await loading.value }
        guard let store else {
            if case .unread = state { state = .unavailable }
            return
        }
        let task = Task { [accountID] in
            let saved = try? await store.allowedImageSenders(accountID: accountID)
            state = saved.map(State.loaded) ?? .unavailable
            loading = nil
        }
        loading = task
        await task.value
    }

    /// Applies a change the store has already saved. Call `load` first, so
    /// the change lands on top of the saved list.
    func record(_ allowed: Bool, address: String) {
        guard case .loaded(var senders) = state else { return }
        let address = EmailAddress(address: address).normalized
        if allowed { senders.insert(address) } else { senders.remove(address) }
        state = .loaded(senders)
    }
}
