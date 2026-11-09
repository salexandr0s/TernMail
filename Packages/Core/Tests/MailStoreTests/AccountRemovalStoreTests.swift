import Foundation
import GmailAPI
import GRDB
import Testing
@testable import MailStore

@Suite struct AccountRemovalStoreTests {
    @Test func pendingRemovalSurvivesAccountDeletionAndReopenWithoutRestoringTheAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TernRemovalStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "config.sqlite")
        let store = try AccountStore.open(at: path)
        let account = AccountRecord(id: "account", email: "audit@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        try await store.save(account)
        let pending = try await store.beginAccountRemoval(accountID: account.id, draftIDs: ["draft-to-delete"])
        // A crash before deleting the account record must not restore it.
        #expect(try await store.accounts().isEmpty)
        await #expect(throws: AccountRemovalError.self) { try await store.save(account) }
        try await store.deleteAccount(id: account.id)
        try await store.completeAccountRemovalStage(.account, removal: pending)

        let reopened = try AccountStore.open(at: path)
        let restored = try #require(try await reopened.pendingAccountRemovals().first)
        #expect(restored.generation == pending.generation)
        #expect(restored.draftIDs == ["draft-to-delete"])
        #expect(restored.completed == [.account])
        #expect(try await reopened.accounts().isEmpty)
        await #expect(throws: AccountRemovalError.self) { try await reopened.finishAccountRemoval(restored) }
        for stage in PendingAccountRemoval.Stage.allCases where stage != .account {
            try await reopened.completeAccountRemovalStage(stage, removal: restored)
        }
        try await reopened.finishAccountRemoval(restored)
        try await reopened.save(account)
        #expect(try await reopened.accounts().map(\.id) == [account.id])
        #expect(try await reopened.pendingAccountRemovals().isEmpty)
    }

    @Test func unsafeFileIdentitiesAreRejectedBeforeCheckpointingAndOldGenerationCannotCompleteANewRemoval() async throws {
        let store = try AccountStore.inMemory()
        for unsafe in ["", ".", "..", "../other", "folder/other", "folder\\other", "folder:other", "nul\0name"] {
            await #expect(throws: AccountRemovalError.self) {
                try await store.beginAccountRemoval(accountID: unsafe, draftIDs: [])
            }
            await #expect(throws: AccountRemovalError.self) {
                try await store.beginAccountRemoval(accountID: "account", draftIDs: [unsafe])
            }
        }
        #expect(try await store.pendingAccountRemovals().isEmpty)
        let old = try await store.beginAccountRemoval(accountID: "account", draftIDs: ["old-draft"])
        for stage in PendingAccountRemoval.Stage.allCases { try await store.completeAccountRemovalStage(stage, removal: old) }
        try await store.finishAccountRemoval(old)
        let fresh = try await store.beginAccountRemoval(accountID: "account", draftIDs: ["new-draft"])
        #expect(fresh.generation != old.generation)
        await #expect(throws: AccountRemovalError.self) { try await store.completeAccountRemovalStage(.credentials, removal: old) }
        await #expect(throws: AccountRemovalError.self) { try await store.finishAccountRemoval(old) }
        #expect(try await store.pendingAccountRemovals() == [fresh])
    }

    /// The Focus filter and account removal can open a second connection
    /// while the app writes. Its write waits instead of failing as locked.
    @Test(.timeLimit(.minutes(1))) func secondConnectionWaitsForAnOverlappingWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TernSharedOpen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.sqlite")
        let calendarURL = directory.appending(path: "calendar.sqlite")
        let accounts = try AccountStore.open(at: configURL)
        let calendar = try CalendarStore.open(at: calendarURL)
        let account = AccountRecord(id: "account", email: "audit@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        let event = GoogleCalendarEvent(rawValue: ["id": .string("event"), "summary": .string("Meeting")])

        try await Self.whileWriting(accounts.writer) {
            try await AccountStore.open(at: configURL).save(account)
        }
        try await Self.whileWriting(calendar.writer) {
            try await CalendarStore.open(at: calendarURL).cacheEvent(event, accountID: account.id, calendarID: "calendar")
        }
        #expect(try await accounts.accounts().map(\.id) == [account.id])
        #expect(try await calendar.events(accountID: account.id, calendarID: "calendar").map(\.id) == [event.id])
    }

    /// Runs `body` while `writer` holds the write lock for half a second.
    private static func whileWriting(_ writer: any DatabaseWriter, _ body: () async throws -> Void) async throws {
        let (locked, signal) = AsyncStream.makeStream(of: Void.self)
        async let release: Void = writer.write { _ in
            signal.yield()
            // A fixed hold: `body` can't finish until this lock is released,
            // and nothing shows when its write starts waiting. Half a second
            // is far longer than `body` takes to reach its write.
            Thread.sleep(forTimeInterval: 0.5)
        }
        for await _ in locked { break }
        try await body()
        try await release
    }
}
