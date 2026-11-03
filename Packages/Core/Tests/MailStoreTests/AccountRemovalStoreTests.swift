import Foundation
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
}
