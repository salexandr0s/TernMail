import Foundation
@testable import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

private let day: TimeInterval = 24 * 60 * 60

@Suite struct ContactSyncTests {
    @Test func aTokenForOtherFieldsIsNeverSentAndAFailedSyncKeepsTheOldToken() async throws {
        let (engine, cache, _, people, _, _) = try await makeContactsEngine()
        try await seedState(cache, .connection, token: "old", fields: "names", fullSyncAt: baseDate)
        try await seedState(cache, .other, token: "kept", fullSyncAt: baseDate)
        await people.fail("otherContacts kept", with: GmailError.server(status: 503))

        await #expect(throws: GmailError.server(status: 503)) { try await engine.syncContacts() }
        #expect(await people.calls(.connections) == ["full"])
        let connections = try #require(try await state(cache, .connection))
        #expect(connections.syncToken == "connections-1")
        #expect(connections.fields == PeopleClient.fields)
        #expect(try await state(cache, .other)?.syncToken == "kept")
    }

    @Test func aRejectedTokenCountsAsExpiredOnlyOnceItIsSevenDaysOld() async throws {
        let (engine, cache, _, people, clock, _) = try await makeContactsEngine()
        try await seedState(cache, .connection, token: "t", fullSyncAt: baseDate.addingTimeInterval(-day))
        await people.fail("connections t", with: PeopleError.syncTokenRejected(status: 400))
        await #expect(throws: PeopleError.syncTokenRejected(status: 400)) { try await engine.syncContacts() }

        // Six days later the token is 7 days old, and the full sync it needs fails.
        clock.advance(6 * day)
        await people.fail("connections full", with: GmailError.http(status: 400, reason: nil))
        await #expect(throws: GmailError.http(status: 400, reason: nil)) { try await engine.syncContacts() }
        // Until the next full sync is allowed, a rejection of the old token isn't reported.
        clock.advance(3600)
        await people.fail("connections t", with: PeopleError.syncTokenRejected(status: 400))
        try await engine.syncContacts()
        #expect(await people.calls(.connections) == ["t", "full", "t"])
    }

    @Test func anExpiredTokenStartsAFullSyncAtMostOnceADay() async throws {
        let (engine, cache, _, people, clock, sleeps) = try await makeContactsEngine()
        try await seedState(cache, .connection, token: "t", fullSyncAt: baseDate.addingTimeInterval(-day))
        await people.fail("connections t", with: PeopleError.syncTokenExpired, times: 3)
        // The quota for a full sync's first page has run out.
        await people.fail("connections full", with: GmailError.rateLimited, times: 4)
        await #expect(throws: GmailError.rateLimited) { try await engine.syncContacts() }
        #expect(await sleeps.durations == [.seconds(60), .seconds(120), .seconds(240)])

        clock.advance(3600)
        try await engine.syncContacts()
        clock.advance(day)
        try await engine.syncContacts()
        #expect(await people.calls(.connections) == ["t", "full", "full", "full", "full", "t", "t", "full"])
        #expect(try await state(cache, .connection)?.syncToken == "connections-1")
    }

    @Test func turningContactsOffDuringASyncLeavesNoContacts() async throws {
        let (engine, cache, accounts, people, _, _) = try await makeContactsEngine()
        await people.hold("connections full")
        let syncing = Task { try await engine.syncContacts() }
        while await !people.isHolding { await Task.yield() }

        // What the app does when the user turns Contacts off.
        try await accounts.updateAccount(id: account) { $0.enabledFeatures = [] }
        try await cache.write { tx in try tx.deleteContacts(accountID: account) }
        await people.release()
        try await syncing.value

        #expect(try await state(cache, .connection) == nil)
        #expect(await people.calls(.otherContacts).isEmpty)
    }
}

/// One account's contacts in the People API. `calls` lists "full" for a full
/// sync and the token for an incremental one. Unscripted calls succeed with
/// no changes and the token "<source>-<n>".
actor FakePeople: PeopleService {
    private var log: [(source: PeopleClient.Source, call: String)] = []
    private var errors: [String: [any Error & Sendable]] = [:]
    private var heldCall: String?
    private var held: CheckedContinuation<Void, Never>?
    private var issued: [PeopleClient.Source: Int] = [:]

    func calls(_ source: PeopleClient.Source) -> [String] {
        log.filter { $0.source == source }.map(\.call)
    }

    /// The next `times` of `call` ("connections full", "otherContacts <token>") throw `error`.
    func fail(_ call: String, with error: any Error & Sendable, times: Int = 1) {
        errors[call, default: []] += Array(repeating: error, count: times)
    }

    /// The next `call` waits until `release()`.
    func hold(_ call: String) { heldCall = call }
    var isHolding: Bool { held != nil }
    func release() {
        held?.resume()
        held = nil
    }

    func sync(_ source: PeopleClient.Source, syncToken: String?) async throws -> ContactSync {
        let call = syncToken ?? "full"
        log.append((source, call))
        let key = "\(source.rawValue) \(call)"
        if let error = errors[key]?.first {
            errors[key]?.removeFirst()
            throw error
        }
        if heldCall == key {
            heldCall = nil
            await withCheckedContinuation { held = $0 }
        }
        issued[source, default: 0] += 1
        return ContactSync(people: [], syncToken: "\(source.rawValue)-\(issued[source, default: 0])")
    }
}

/// Records the engine's waits and returns at once.
actor SleepLog {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) { durations.append(duration) }
}

/// An engine for an account with Contacts on.
func makeContactsEngine() async throws -> (SyncEngine, MailCache, AccountStore, FakePeople, TestClock, SleepLog) {
    let cache = try MailCache.inMemory()
    let accounts = try AccountStore.inMemory()
    try await accounts.save(AccountRecord(
        id: account, email: "me@example.com", displayName: "Me",
        grantedScopes: GoogleScopes.base + GoogleScopes.required(for: .contacts), addedAt: baseDate,
        enabledFeatures: [AccountFeature.contacts.rawValue]
    ))
    let people = FakePeople()
    let clock = TestClock()
    let sleeps = SleepLog()
    let engine = SyncEngine(
        accountID: account,
        sender: EmailAddress(name: "Me", address: "me@example.com"),
        outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernTests-\(UUID().uuidString)", directoryHint: .isDirectory),
        gmail: FakeGmail(),
        people: people,
        accounts: accounts,
        cache: cache,
        sendsAutomatically: false,
        sleep: { await sleeps.record($0) },
        now: clock.now
    )
    return (engine, cache, accounts, people, clock, sleeps)
}

/// Stores a source's state as a full sync at `fullSyncAt` would leave it.
private func seedState(
    _ cache: MailCache, _ source: ContactSource, token: String, fields: String = PeopleClient.fields, fullSyncAt: Date
) async throws {
    try await cache.write { tx in
        try tx.applyContactSync([], source: source, syncToken: token, fields: fields, isFullSync: true, now: fullSyncAt, accountID: account)
    }
}

private func state(_ cache: MailCache, _ source: ContactSource) async throws -> ContactSyncRecord? {
    try await cache.read { tx in try tx.contactSync(source: source, accountID: account) }
}
