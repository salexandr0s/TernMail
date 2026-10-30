import Foundation
import Testing
@testable import MailStore

@Suite struct AttachmentCategoryOverrideTests {
    @Test func newerManualChoiceWinsOverStaleIndexReadAndLegacyImport() async throws {
        let (store, cache) = try await setup()
        let first = try await store.saveAttachmentCategoryOverride(.init(accountID: "a", messageID: "m", partID: "1", category: .invoice))
        let second = try await store.saveAttachmentCategoryOverride(.init(accountID: "a", messageID: "m", partID: "1", category: .uncategorized))
        #expect(second.revision > first.revision)
        try await cache.applyAttachmentCategoryOverrides([second])
        try await cache.applyAttachmentCategoryOverrides([first])
        #expect(try await category(cache) == .uncategorized)
        try await cache.write { try $0.setAttachmentCategory(.contract, accountID: "a", messageID: "m", partID: "1") }
        let legacy = try await cache.attachmentCategorySnapshot()
        #expect(legacy.first?.category == .contract)
        try await store.importAttachmentCategoryOverrides(legacy)
        #expect(try await store.attachmentCategoryOverrides(accountID: "a").first == second)
        #expect(try await store.attachmentCategoryOverrides(accountID: "a", messageIDs: []).isEmpty)
    }

    @Test func configCategorySurvivesFullCachePurgeAndNewMetadata() async throws {
        let (store, cache) = try await setup()
        try await cache.write { try $0.setAttachmentCategory(.receipt, accountID: "a", messageID: "m", partID: "1") }
        try await store.importAttachmentCategoryOverrides(cache.attachmentCategorySnapshot())
        let saved = try await store.attachmentCategoryOverrides(accountID: "a")
        #expect(saved.first?.category == .receipt)
        try await cache.resetDisposableCache()
        try await seedLibrary(cache)
        try await cache.applyAttachmentCategoryOverrides(saved)
        #expect(try await category(cache) == .receipt)
        try await store.deleteAccount(id: "a")
        try await store.save(.init(id: "a", email: "a@example.test", displayName: nil, grantedScopes: [], addedAt: .distantPast))
        #expect(try await store.attachmentCategoryOverrides(accountID: "a").isEmpty)
    }

    private func setup() async throws -> (AccountStore, MailCache) {
        let store = try AccountStore.inMemory()
        try await store.save(.init(id: "a", email: "a@example.test", displayName: nil, grantedScopes: [], addedAt: .distantPast))
        let cache = try MailCache.inMemory()
        try await seedLibrary(cache)
        return (store, cache)
    }

    private func seedLibrary(_ cache: MailCache) async throws {
        let message = MessageRecord(accountID: "a", id: "m", threadID: "t", historyID: 1, date: .distantPast,
            snippet: "", sender: "sender@example.test", recipients: "a@example.test", cc: nil, subject: "Document", sizeEstimate: 1)
        try await cache.write { tx in
            try tx.replaceLibraryAttachments([.init(accountID: "a", messageID: "m", partID: "1", attachmentID: "data", filename: "invoice.pdf",
                mimeType: "application/pdf", size: 100, isInline: false)], message: message, labelIDs: [])
        }
    }

    private func category(_ cache: MailCache) async throws -> AttachmentCategory? {
        try await cache.read { try $0.libraryAttachment(accountID: "a", messageID: "m", partID: "1")?.category }
    }
}
