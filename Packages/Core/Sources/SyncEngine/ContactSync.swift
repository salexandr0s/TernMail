import Foundation
import GmailAPI
import MailStore

/// The People API call contact sync makes. `PeopleClient` adopts it.
public protocol PeopleService: Sendable {
    /// Every page of `source`: everyone without `syncToken`, otherwise the
    /// changes since it, with the token from the last page.
    func sync(_ source: PeopleClient.Source, syncToken: String?) async throws -> ContactSync
}

extension PeopleClient: PeopleService {}

// Saved contacts and other contacts are kept in the cache for address
// suggestions. Both sources follow the same rules, each with its own token.
extension SyncEngine {
    /// Google expires sync tokens 7 days after the full sync that issued them.
    static let contactTokenLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Full syncs of a source, failed ones included, start at most this
    /// often, since the first page of each has its own small quota.
    static let fullContactSyncSpacing: TimeInterval = 24 * 60 * 60
    /// Waits before each retry of a full sync that failed with a retryable
    /// error, starting at the minute a full sync's first-page quota asks for.
    static let fullContactSyncRetryDelays: [Duration] = [.seconds(60), .seconds(120), .seconds(240)]

    /// Syncs both sources while Contacts is on for the account, unless the
    /// last sync began less than `maxAge` seconds ago. A call during a sync
    /// waits for it. A source that fails doesn't stop the other, and the
    /// first error is thrown once both have run.
    public func syncContacts(olderThan maxAge: TimeInterval = 0) async throws {
        if isStopped { throw CancellationError() }
        if let running = contactSyncTask { return try await running.value }
        if let last = lastContactSyncAt, now().timeIntervalSince(last) < maxAge { return }
        let task = Task {
            defer { contactSyncTask = nil }
            try await runContactSync()
        }
        contactSyncTask = task
        try await task.value
    }

    private func runContactSync() async throws {
        guard let people else { return }
        lastContactSyncAt = now()
        var firstError: (any Error)?
        for source in ContactSource.allCases {
            guard try await contactsAreOn() else { break }
            do {
                try await syncContacts(from: source, using: people)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Off without a config store.
    private func contactsAreOn() async throws -> Bool {
        guard let accounts else { return false }
        let accountID = accountID
        guard let account = try await accounts.accounts().first(where: { $0.id == accountID }) else { return false }
        return AccountFeature.named(account.enabledFeatures).contains(.contacts)
    }

    /// Runs an incremental sync while the token is usable, and a full sync
    /// when there is none, when it was issued for other fields, when it is 7
    /// days old, or when Google says it expired.
    private func syncContacts(from source: ContactSource, using people: any PeopleService) async throws {
        let accountID = accountID
        let state = try await cache.read { tx in try tx.contactSync(source: source, accountID: accountID) }
        let token = state?.fields == PeopleClient.fields ? state?.syncToken : nil
        let isTokenOld = state.map { now().timeIntervalSince($0.lastFullSyncAt) >= Self.contactTokenLifetime } ?? true
        if token == nil || isTokenOld {
            if try await fullContactSync(source, using: people) { return }
            // Today's full sync has run. An old token may still work until the next.
        }
        guard let token else { return }
        let changes: ContactSync
        do {
            changes = try await people.sync(source.peopleSource, syncToken: token)
        } catch PeopleError.syncTokenExpired {
            _ = try await fullContactSync(source, using: people)
            return
        } catch PeopleError.syncTokenRejected where isTokenOld {
            // Counts as expired, and today's full sync has already run. A
            // younger token's rejection is thrown, so a 400 that keeps coming
            // back can't start a full sync on every call.
            return
        }
        try await applyContacts(changes, source: source, isFullSync: false)
    }

    /// Replaces the source's contacts with everyone Google lists. Returns
    /// false without a request when the last full sync began less than a day ago.
    private func fullContactSync(_ source: ContactSource, using people: any PeopleService) async throws -> Bool {
        let start = now()
        if let last = fullContactSyncStarts[source], start.timeIntervalSince(last) < Self.fullContactSyncSpacing {
            return false
        }
        fullContactSyncStarts[source] = start
        var delays = Self.fullContactSyncRetryDelays[...]
        while true {
            do {
                let everyone = try await people.sync(source.peopleSource, syncToken: nil)
                try await applyContacts(everyone, source: source, isFullSync: true)
                return true
            } catch let error as GmailError where error.isRetryable && !delays.isEmpty {
                try await sleep(delays.removeFirst())
            }
        }
    }

    /// Writes a whole sync with its token, so a stored token never skips a page.
    private func applyContacts(_ sync: ContactSync, source: ContactSource, isFullSync: Bool) async throws {
        let (accountID, now) = (accountID, now())
        try await write { tx in
            try tx.applyContactSync(
                sync.people, source: source, syncToken: sync.syncToken, fields: PeopleClient.fields,
                isFullSync: isFullSync, now: now, accountID: accountID
            )
        }
        // Turning Contacts off updates the account first and then deletes its
        // contacts, outside the engine. A write that landed after that delete
        // sees the feature off here and is undone.
        if try await !contactsAreOn() {
            try await write { tx in try tx.deleteContacts(accountID: accountID) }
        }
    }
}

extension ContactSource {
    var peopleSource: PeopleClient.Source {
        switch self {
        case .connection: .connections
        case .other: .otherContacts
        }
    }
}
