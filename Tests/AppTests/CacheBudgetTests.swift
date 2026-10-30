import Foundation
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct CacheBudgetTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func trimsOnlyUnprotectedManagedContentAndRetainsPendingAlertSources() async throws {
        let cache = try MailCache.inMemory()
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "a", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: date))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let free = try await seed("free", in: cache, directory: directory)
        let visible = try await seed("visible", in: cache, directory: directory)
        let alert = try await seed("alert", in: cache, directory: directory)
        try await store.setMailAlertBaseline(accountID: "a", historyID: 1, at: date)
        try await store.enqueueMailAlerts(accountID: "a", expectedHistoryID: 1, to: 3,
            alerts: [PendingMailAlert(accountID: "a", messageID: "alert", threadID: "alert", addedHistoryID: 2)])
        let model = CacheMaintenanceModel(cache: cache, store: store, attachmentDirectory: directory, budgetBytes: 1,
            keeping: { [CacheThreadReference(accountID: "a", threadID: "visible")] }, now: { date })
        await model.enforceBudget()
        #expect(model.error == nil)
        #expect(!FileManager.default.fileExists(atPath: free.path))
        #expect(FileManager.default.fileExists(atPath: visible.path))
        #expect(FileManager.default.fileExists(atPath: alert.path))
        #expect(try await cache.read { try $0.message(id: "free", accountID: "a") } == nil)
        #expect(try await cache.read { try $0.body(messageID: "visible", accountID: "a") } != nil)
        #expect(try await cache.read { try $0.body(messageID: "alert", accountID: "a") } != nil)
        #expect(model.protectedBudgetLimit)
    }

    @Test func recoverableDraftPreventsTrimmingAndSuspendRejectsNewPasses() async throws {
        let cache = try MailCache.inMemory()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await seed("old", in: cache, directory: directory)
        let timestamp = date
        try await cache.write { tx in
            try tx.insertLocalDraft(LocalDraft(accountID: "a", kind: .new, rfcMessageID: "<pending@example.com>", now: timestamp))
        }
        let model = CacheMaintenanceModel(cache: cache, store: nil, attachmentDirectory: directory, budgetBytes: 1, now: { date })
        await model.enforceBudget()
        #expect(model.readiness?.localDraftCount == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await cache.read { try $0.body(messageID: "old", accountID: "a") } != nil)
        await model.suspend()
        await model.enforceBudget()
        #expect(!model.isTrimming)
        #expect(FileManager.default.fileExists(atPath: file.path))
        model.resume()
    }

    @Test func emptyInboxMetadataDoesNotStarveLaterEvictableContent() async throws {
        let cache = try MailCache.inMemory()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = date
        try await cache.write { tx in
            let empty = (0..<129).map { index in
                MessageRecord(accountID: "a", id: "empty-\(index)", threadID: "empty-\(index)", historyID: 1,
                    date: timestamp, snippet: "", sender: "sender@example.com", recipients: "me@example.com", cc: nil,
                    subject: "Inbox", sizeEstimate: 1)
            }
            _ = try tx.upsertMessages(empty.map { .init(record: $0, labelIDs: ["INBOX"]) })
            try tx.rebuildThreads(Set(empty.map(\.threadID)), accountID: "a")
        }
        let removable = try await seed("z-removable", in: cache, directory: root)
        let model = CacheMaintenanceModel(cache: cache, store: nil, attachmentDirectory: root, budgetBytes: 1, now: { date })
        await model.enforceBudget()
        #expect(model.error == nil)
        #expect(!FileManager.default.fileExists(atPath: removable.path))
        #expect(try await cache.read { try $0.message(id: "z-removable", accountID: "a") } == nil)
        #expect(try await cache.read { try $0.message(id: "empty-0", accountID: "a") } != nil)
    }

    @Test func fileCleanupRejectsRecentSymlinkedAndExternalFiles() throws {
        let root = try temporaryDirectory()
        let external = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        let stale = root.appending(path: "stale")
        let recent = root.appending(path: "recent")
        for folder in [stale, recent, external] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "file.pdf")
            try Data("document".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: folder == recent ? date : date.addingTimeInterval(-3600)], ofItemAtPath: file.path)
        }
        let link = root.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        #expect(ManagedAttachmentFiles.canRemove(stale, within: root, now: date))
        #expect(!ManagedAttachmentFiles.canRemove(recent, within: root, now: date))
        #expect(!ManagedAttachmentFiles.canRemove(external, within: root, now: date))
        #expect(!ManagedAttachmentFiles.canRemove(link, within: root, now: date))
        #expect(try ManagedAttachmentFiles.remove(stale, within: root, now: date) > 0)
        #expect(FileManager.default.fileExists(atPath: external.appending(path: "file.pdf").path))
        #expect(FileManager.default.fileExists(atPath: recent.appending(path: "file.pdf").path))
    }

    @Test func duplicatePreviewUpdatesAndMultipleViewsKeepOldFileUntilLastLeaseCloses() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "report.pdf")
        try Data("preview".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-24 * 3600)], ofItemAtPath: file.path)
        let registry = AttachmentPreviewRegistry()
        let first = UUID(), second = UUID()
        registry.update(file, lease: first)
        registry.update(file, lease: first)
        registry.update(file, lease: second)
        registry.release(first)
        #expect(!ManagedAttachmentFiles.canRemove(folder, within: root, now: date, protectedURLs: registry.activeURLs))
        registry.release(second)
        #expect(ManagedAttachmentFiles.canRemove(folder, within: root, now: date, protectedURLs: registry.activeURLs))
    }

    private func seed(_ id: String, in cache: MailCache, directory: URL) async throws -> URL {
        let timestamp = date
        let attachment = AttachmentRecord(accountID: "a", messageID: id, partID: "1", attachmentID: "attachment",
            filename: "report.pdf", mimeType: "application/pdf", size: 12, isInline: false)
        let message = MessageRecord(accountID: "a", id: id, threadID: id, historyID: 1,
            date: date.addingTimeInterval(-90 * 86400), snippet: "Mail", sender: "sender@example.com",
            recipients: "me@example.com", cc: nil, subject: "Old mail", sizeEstimate: 12)
        try await cache.write { tx in
            _ = try tx.upsertMessages([.init(record: message, labelIDs: [])])
            try tx.rebuildThreads([id], accountID: "a")
            try tx.saveBodies([MessageBodyRecord(accountID: "a", messageID: id, html: "<b>Body</b>", plainText: "Body", fetchedAt: timestamp)])
            try tx.replaceAttachments([attachment], messageID: id, accountID: "a")
        }
        let folder = SyncEngine.attachmentCacheFolder(for: attachment, in: directory.appending(path: "a"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: attachment.filename)
        try Data(repeating: 7, count: attachment.size).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-3600)], ofItemAtPath: file.path)
        return file
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tern-cache-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
