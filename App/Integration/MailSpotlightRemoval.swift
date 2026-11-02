import CoreSpotlight
import Foundation
import Observation

/// Save deletion intent before asking Spotlight, so a failed privacy change
/// can finish after the app closes or its account is removed.
@MainActor @Observable
final class MailSpotlightRemoval {
    private static let allKey = "tern.spotlight.pendingRemoval.all"
    private static let domainsKey = "tern.spotlight.pendingRemoval.accounts"
    private(set) var error: String?
    private(set) var isRemoving = false
    private(set) var hasPendingRemoval: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let remove: @Sendable ([String]?) async throws -> Void
    @ObservationIgnored private var revision = 0

    init(defaults: UserDefaults = .standard,
         remove: @escaping @Sendable ([String]?) async throws -> Void = { accounts in
             if let accounts {
                 try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: accounts)
             } else {
                 try await CSSearchableIndex.default().deleteAllSearchableItems()
             }
         }) {
        self.defaults = defaults
        self.remove = remove
        hasPendingRemoval = defaults.bool(forKey: Self.allKey)
            || !(defaults.stringArray(forKey: Self.domainsKey) ?? []).isEmpty
    }

    func requestAll() {
        revision &+= 1
        defaults.set(true, forKey: Self.allKey)
        defaults.removeObject(forKey: Self.domainsKey)
        hasPendingRemoval = true
    }

    func request(accounts: Set<String>) {
        guard !accounts.isEmpty else { return }
        revision &+= 1
        if !defaults.bool(forKey: Self.allKey) {
            let pending = Set(defaults.stringArray(forKey: Self.domainsKey) ?? []).union(accounts)
            defaults.set(pending.sorted(), forKey: Self.domainsKey)
        }
        hasPendingRemoval = true
    }

    /// The indexer's serial queue calls this before adding more mail.
    @discardableResult
    func performPending(didRemove: @MainActor ([String]?) -> Void = { _ in }) async -> Bool {
        guard !isRemoving else { return false }
        isRemoving = true
        defer { isRemoving = false }
        while hasPendingRemoval {
            let current = revision
            let accounts: [String]? = defaults.bool(forKey: Self.allKey)
                ? nil : defaults.stringArray(forKey: Self.domainsKey) ?? []
            do {
                try Task.checkCancellation()
                try await remove(accounts)
                try Task.checkCancellation()
            } catch is CancellationError {
                return false
            } catch {
                self.error = "Mail could not be removed from Spotlight. Retry to finish removing it."
                return false
            }
            didRemove(accounts)
            // Requests arriving during the OS call must receive their own pass.
            if revision == current {
                defaults.removeObject(forKey: Self.allKey)
                defaults.removeObject(forKey: Self.domainsKey)
                hasPendingRemoval = false
            }
        }
        error = nil
        return true
    }
}
