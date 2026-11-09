import Foundation
import GRDB
import Testing
@testable import MailStore

@Suite struct CacheRecoveryTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func aNewCacheKeepsDraftsAndQueuedChangesButNotMail() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        let old = try MailCache(writer: pool)
        let draft = LocalDraft(id: "draft", accountID: "a", kind: .new, rfcMessageID: "<draft@example.test>", now: date)
        let message = MessageRecord(accountID: "a", id: "m", threadID: "t", historyID: 1, date: date,
            snippet: "", sender: "sender@example.test", recipients: "me@example.test", cc: nil, subject: "Mail", sizeEstimate: 1)
        try await old.write { tx in
            try tx.insertLocalDraft(draft)
            _ = try tx.addOutgoingAttachment(.init(localDraftID: "draft", filename: "plan.pdf", mimeType: "application/pdf",
                size: 1, path: "draft/plan.pdf"), now: date)
            try tx.upsertMessages([.init(record: message, labelIDs: [])])
            try tx.rebuildThreads(["t"], accountID: "a")
            _ = try tx.enqueue(.modifyMessages, accountID: "a", messageIDs: ["m"], add: [SystemLabel.starred], now: date, notBefore: date)
        }
        let saved = try await old.read { tx in
            (try tx.localDraft(id: "draft"), try tx.outgoingAttachments(localDraftID: "draft"), try tx.allActions(accountID: "a"))
        }
        try #require(saved.0 != nil && saved.1.count == 1 && saved.2.count == 1)
        try pool.close()

        let recovery = try MailCache.recover(at: url, setAsideAt: date)
        #expect(recovery.outcome == .complete && recovery.draftCount == 1 && recovery.changeCount == 1)
        #expect(recovery.folder.lastPathComponent == MailCache.setAsideFolderName(at: date))
        #expect(FileManager.default.fileExists(atPath: recovery.folder.appending(path: "cache.sqlite").path(percentEncoded: false)))
        // Nothing else is left beside the new cache, such as the folder it was built in.
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(Set(entries) == ["cache.sqlite", recovery.folder.lastPathComponent])

        let cache = try MailCache.open(at: url)
        let kept = try await cache.read { tx in
            (try tx.localDraft(id: "draft"), try tx.outgoingAttachments(localDraftID: "draft"), try tx.allActions(accountID: "a"))
        }
        #expect(kept.0 == saved.0 && kept.1 == saved.1 && kept.2 == saved.2)
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: "a") }.isEmpty)
    }

    @Test func aFileThatIsNotADatabaseStillGetsANewCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let damaged = Data(repeating: 0x5A, count: 4096)
        try damaged.write(to: url)

        let recovery = try MailCache.recover(at: url, setAsideAt: date)
        #expect(recovery.outcome == .unreadable && recovery.draftCount == 0 && recovery.changeCount == 0)
        #expect(try Data(contentsOf: recovery.folder.appending(path: "cache.sqlite")) == damaged)
        let cache = try MailCache.open(at: url)
        #expect(try await cache.read { try $0.localDrafts(accountID: "a") }.isEmpty)
    }

    @Test func aDraftOnlyInTheLogACrashLeftIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        try await leaveCrashedCache(at: url)

        let recovery = try MailCache.recover(at: url, setAsideAt: date)
        #expect(recovery.outcome == .complete && recovery.draftCount == 1)
    }

    /// Tern can quit after any move: `movesMade` of the old file, its log,
    /// its shared memory and then the new cache.
    @Test(arguments: 0...4) func anOpenFinishesARecoveryThatStoppedPartway(movesMade: Int) async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let journal = try await stopRecovery(at: url, afterMoves: movesMade)

        let cache = try MailCache.open(at: url)
        #expect(try await cache.read { try $0.localDraft(id: "draft") } != nil)
        // The old log is still with its file, and nothing else is left
        // beside the new cache, such as the journal.
        let folder = journal.folder(at: url)
        #expect(Set(try files.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
            == ["cache.sqlite", "cache.sqlite-wal", "cache.sqlite-shm"])
        let entries = Set(try files.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
        #expect(entries.subtracting(["cache.sqlite-wal", "cache.sqlite-shm"]) == ["cache.sqlite", folder.lastPathComponent])
    }

    @Test func finishingARecoveryReportsWhatItKeptOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let journal = try await stopRecovery(at: url, afterMoves: 2)

        // The app shows this before the cache opens, and the next launch has nothing to show.
        #expect(try MailCache.finishRecovery(at: url) == journal.recovery(at: url))
        #expect(try MailCache.finishRecovery(at: url) == nil)
    }

    /// Leaves the recovery of a crashed cache at `url` as Tern quitting after
    /// `moves` of its moves would.
    private func stopRecovery(at url: URL, afterMoves moves: Int) async throws -> CacheRecoveryJournal {
        let files = FileManager.default
        try await leaveCrashedCache(at: url)
        let journal = try MailCache.prepareRecovery(at: url, setAsideAt: date)
        let planned = journal.oldFiles(at: url).filter { files.fileExists(atPath: $0.original.path(percentEncoded: false)) }
            + [(original: journal.stagedCache(at: url), setAside: url)]
        try #require(planned.count == 4)
        for move in planned.prefix(moves) { try files.moveItem(at: move.original, to: move.setAside) }
        return journal
    }

    /// Writes a draft and copies the cache's files to `url` while it's open.
    /// The copies are what a crash leaves: nothing has checkpointed the log,
    /// so the draft is only in the -wal file.
    private func leaveCrashedCache(at url: URL) async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let path = source.appending(path: url.lastPathComponent).path(percentEncoded: false)
        let pool = try DatabasePool(path: path)
        let old = try MailCache(writer: pool)
        let draft = LocalDraft(id: "draft", accountID: "a", kind: .new, rfcMessageID: "<draft@example.test>", now: date)
        try await old.write { tx in try tx.insertLocalDraft(draft) }
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: url.path(percentEncoded: false) + suffix)
        }
        try pool.close()
    }

    @Test func aLockedCacheIsInUseRatherThanDamaged() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        // Another connection holds the file, as a second copy of Tern would.
        let holder = try DatabaseQueue(path: url.path(percentEncoded: false))
        defer { try? holder.close() }
        let error = try holder.inDatabase { db -> (any Error)? in
            try db.execute(sql: "CREATE TABLE held(x)")
            try db.execute(sql: "BEGIN EXCLUSIVE")
            defer { try? db.execute(sql: "ROLLBACK") }
            do { _ = try MailCache.open(at: url) } catch { return error }
            return nil
        }
        #expect(error.map(CacheOpenProblem.init) == .inUse)
    }
}
