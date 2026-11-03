import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct AccountCleanupCoordinatorTests {
    @Test func credentialAndFileFailuresRemainPendingAcrossRelaunchAndDoNotRemoveAnotherAccount() async throws {
        let fixture = try CleanupFixture()
        let firstStore = try AccountStore.open(at: fixture.configURL)
        try await fixture.saveAccounts(in: firstStore)
        fixture.failCredentials = true
        fixture.failDraft = true
        let first = fixture.coordinator(store: firstStore)
        #expect(try await first.remove(accountID: "account", draftIDs: ["draft"]) == false)
        #expect(fixture.injectedFileFailures == 1)
        #expect(try await firstStore.accounts().map(\.id) == ["other"])
        #expect(fixture.credentials["account"] == "old")
        #expect(fixture.cacheAccounts == ["other"])
        #expect(!FileManager.default.fileExists(atPath: fixture.download("account").path))
        #expect(FileManager.default.fileExists(atPath: fixture.draft("draft").path))
        let pending = try #require(try await firstStore.pendingAccountRemovals().first)
        #expect(pending.draftIDs == ["draft"])
        #expect(!pending.completed.contains(.credentials))
        #expect(!pending.completed.contains(.files))

        // A new coordinator and database connection model a fresh app launch.
        fixture.failCredentials = false
        fixture.failDraft = false
        let reopened = try AccountStore.open(at: fixture.configURL)
        let relaunched = fixture.coordinator(store: reopened)
        #expect(try await relaunched.retryPending())
        #expect(try await reopened.pendingAccountRemovals().isEmpty)
        #expect(fixture.credentials["account"] == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.draft("draft").path))
        #expect(fixture.credentials["other"] == "other-secret")
        #expect(FileManager.default.fileExists(atPath: fixture.download("other").path))
        #expect(FileManager.default.fileExists(atPath: fixture.draft("other-draft").path))
        #expect(fixture.cacheAccounts == ["other"])
    }

    @Test(.timeLimit(.minutes(1))) func sameAccountSignInWaitsForAnInFlightRetryAndLaterRetriesKeepNewCredentialsAndFiles() async throws {
        let fixture = try CleanupFixture()
        let store = try AccountStore.open(at: fixture.configURL)
        try await fixture.saveAccounts(in: store)
        let coordinator = fixture.coordinator(store: store)
        fixture.failCredentials = true
        #expect(try await coordinator.remove(accountID: "account", draftIDs: ["draft"]) == false)
        await #expect(throws: AccountRemovalError.self) { try await coordinator.prepareForSignIn(accountID: "account") }
        fixture.failCredentials = false
        let gate = CleanupGate()
        fixture.credentialGate = gate
        let retry = Task { try await coordinator.retryPending() }
        await gate.waitUntilEntered()
        var signedIn = false
        let signIn = Task {
            try await coordinator.prepareForSignIn(accountID: "account")
            fixture.credentials["account"] = "new"
            try fixture.createFile(in: fixture.draft("draft"))
            try await store.save(fixture.account("account"))
            signedIn = true
        }
        await Task.yield()
        #expect(!signedIn)
        gate.release()
        #expect(try await retry.value)
        try await signIn.value
        #expect(signedIn)
        #expect(try await coordinator.retryPending())
        #expect(fixture.credentials["account"] == "new")
        #expect(FileManager.default.fileExists(atPath: fixture.draft("draft").path))
        #expect(try await store.accounts().map(\.id).contains("account"))
    }

    @Test func failedAccountDeletionAndCredentialsStayHiddenAfterRelaunch() async throws {
        let fixture = try CleanupFixture()
        let store = try AccountStore.open(at: fixture.configURL)
        try await fixture.saveAccounts(in: store)
        fixture.failAccount = true
        fixture.failCredentials = true
        let coordinator = fixture.coordinator(store: store)
        #expect(try await coordinator.remove(accountID: "account", draftIDs: ["draft"]) == false)
        // The account row and secret still exist, but cannot feed restoration.
        #expect(fixture.credentials["account"] == "old")
        let reopened = try AccountStore.open(at: fixture.configURL)
        let relaunched = fixture.coordinator(store: reopened)
        #expect(try await relaunched.retryPending() == false)
        #expect(try await reopened.accounts().map(\.id) == ["other"])
        await #expect(throws: AccountRemovalError.self) {
            try await relaunched.prepareForSignIn(accountID: "account")
        }
        fixture.failAccount = false
        fixture.failCredentials = false
        #expect(try await relaunched.retryPending())
        #expect(try await reopened.accounts().map(\.id) == ["other"])
        #expect(try await reopened.pendingAccountRemovals().isEmpty)
    }

    @Test func manifestFailurePrecedesInvalidationAndFilePathsStayWithinManagedRoots() async throws {
        let fixture = try CleanupFixture()
        let store = try AccountStore.inMemory()
        let coordinator = fixture.coordinator(store: store)
        var invalidated = false
        await #expect(throws: AccountRemovalError.self) {
            try await coordinator.remove(accountID: "../other", draftIDs: ["draft"]) { invalidated = true }
        }
        #expect(!invalidated)
        #expect(fixture.credentials["other"] == "other-secret")
        #expect(FileManager.default.fileExists(atPath: fixture.download("other").path))
        #expect(throws: AccountRemovalError.self) {
            try AccountCleanupCoordinator.managedChild("../outside", within: fixture.downloads)
        }
    }

    @Test func unopenedCalendarCleanupIsIdempotentAndPreservesOtherAccounts() async throws {
        let fixture = try CleanupFixture()
        let missing = fixture.root.appending(path: "absent.sqlite")
        try await AccountCleanupCoordinator.removeCalendarCache(accountID: "account", at: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let url = fixture.root.appending(path: "calendar.sqlite")
        let store = try CalendarStore.open(at: url)
        let event = GoogleCalendarEvent(id: "event", summary: "Synthetic")
        try await store.cacheEvent(event, accountID: "account", calendarID: "calendar")
        try await store.cacheEvent(event, accountID: "other", calendarID: "calendar")
        try await AccountCleanupCoordinator.removeCalendarCache(accountID: "account", at: url)
        try await AccountCleanupCoordinator.removeCalendarCache(accountID: "account", at: url)
        #expect(try await store.events(accountID: "account", calendarID: "calendar").isEmpty)
        #expect(try await store.events(accountID: "other", calendarID: "calendar") == [event])
    }
}

@MainActor private final class CleanupFixture {
    enum Failure: Error { case injected }
    let root = FileManager.default.temporaryDirectory.appending(path: "TernCleanupTests-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Attachments") }
    var outgoing: URL { root.appending(path: "Outgoing") }
    var configURL: URL { root.appending(path: "config.sqlite") }
    var credentials = ["account": "old", "other": "other-secret"]
    var cacheAccounts: Set<String> = ["account", "other"]
    var failCredentials = false
    var failAccount = false
    var failDraft = false
    var injectedFileFailures = 0
    var credentialGate: CleanupGate?

    init() throws {
        for folder in [download("account"), download("other"), draft("draft"), draft("other-draft")] {
            try createFile(in: folder)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
    func download(_ id: String) -> URL { downloads.appending(path: id) }
    func draft(_ id: String) -> URL { outgoing.appending(path: id) }
    func createFile(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: folder.appending(path: "file"))
    }
    func account(_ id: String) -> AccountRecord {
        AccountRecord(id: id, email: "\(id)@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
    }
    func saveAccounts(in store: AccountStore) async throws {
        try await store.save(account("account"))
        try await store.save(account("other"))
    }
    func coordinator(store: AccountStore) -> AccountCleanupCoordinator {
        AccountCleanupCoordinator(store: store, downloadsRoot: downloads, outgoingRoot: outgoing, operations: .init(
            removeAccount: { [self] id in
                if failAccount { throw Failure.injected }
                try await store.deleteAccount(id: id)
            },
            removeCredentials: { [self] id in
                if failCredentials { throw Failure.injected }
                if let gate = credentialGate { credentialGate = nil; await gate.enter() }
                credentials[id] = nil
            },
            removeCache: { [self] id in cacheAccounts.remove(id) },
            removeWritingStyle: { _ in },
            removeFile: { [self] url in
                if failDraft, url.standardizedFileURL.path == draft("draft").standardizedFileURL.path {
                    injectedFileFailures += 1
                    throw Failure.injected
                }
                do { try FileManager.default.removeItem(at: url) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { return }
            }
        ))
    }
}

@MainActor private final class CleanupGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func enter() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters = []
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
