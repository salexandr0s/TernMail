import Foundation
import GRDB

/// What a new cache kept from one that wouldn't open (`MailCache.recover`).
public struct CacheRecovery: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable, Codable {
        /// Every row of unsent work in the old file was read and kept.
        case complete
        /// Part of the old file couldn't be read, or some of its rows were
        /// unusable, so unsent work may be missing.
        case partial
        /// The old file couldn't be read, so the new cache has none of its work.
        case unreadable
    }

    /// The dated folder beside the cache that holds the old files.
    public var folder: URL
    public var outcome: Outcome
    /// The local drafts kept, messages waiting in the Outbox among them.
    public var draftCount: Int
    /// The queued and failed changes kept, apart from the saves, sends and
    /// discards of drafts.
    public var changeCount: Int
}

/// Why `MailCache.recover` stopped, or why `MailCache.open` couldn't finish
/// a recovery that stopped partway. The old files are back where they were,
/// unless `folder` names the folder they stayed in. Then the next `open` or
/// `recover` moves the rest of them there and the new cache into place.
public struct CacheRecoveryError: Error, LocalizedError {
    public var underlying: any Error
    public var folder: URL?

    public var errorDescription: String? {
        let reason = CacheOpenProblem(underlying) == .diskFull
            ? "There isn't enough free disk space."
            : underlying.localizedDescription
        guard let folder else { return reason + " The current mail cache wasn't moved." }
        return reason + " The current mail cache file is in the folder “\(folder.lastPathComponent)”."
    }
}

/// Why a cache didn't open, as far as the launch screen needs to know.
public enum CacheOpenProblem: Sendable, Equatable {
    /// The disk is full. Once there's space, the cache opens as it was.
    case diskFull
    /// The file is damaged or isn't a database, so only a new cache opens.
    case damaged
    /// Another process, such as a second copy of Tern, holds a lock on the
    /// file. It opens as it was once that process lets go.
    case inUse
    case other

    public init(_ error: any Error) {
        switch error {
        case let error as DatabaseError where error.resultCode == .SQLITE_FULL: self = .diskFull
        case let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB:
            self = .damaged
        case let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED:
            self = .inUse
        case let error as CocoaError where error.code == .fileWriteOutOfSpace: self = .diskFull
        case let error as POSIXError where error.code == .ENOSPC: self = .diskFull
        case let error as CacheRecoveryError: self = CacheOpenProblem(error.underlying)
        default: self = .other
        }
    }
}

extension MailCache {
    /// The name of the folder `recover` moves an old cache into when it runs
    /// at `date`, such as “Old Mail Cache 2026-11-05 at 14.03.22”.
    public static func setAsideFolderName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Old Mail Cache " + formatter.string(from: date)
    }

    /// Starts a new cache at `url` in place of one that won't open, with the
    /// unsent work that can be read from the old one. Nothing may have the
    /// cache open.
    ///
    /// The old file and its `-wal`, `-shm` and `-journal` files move into a
    /// folder beside it named for `date` (`setAsideFolderName`), and nothing
    /// deletes them. The new cache gets every readable, usable row of local
    /// drafts, with their attachment rows and invitation answers, and of
    /// queued and failed changes, with their unread count adjustments. Mail
    /// itself syncs again from Gmail. A file that can't be read at all still
    /// gets a new, empty cache.
    ///
    /// The new cache is complete before anything moves, so a failure, such
    /// as a full disk, leaves the old file where it was. A journal beside the
    /// cache lists the moves before the first one is made, so when Tern quits
    /// partway the next `open` or `recover` makes the rest. A log then never
    /// ends up apart from its database file, and the work kept still reaches
    /// the new cache.
    public static func recover(at url: URL, setAsideAt date: Date) throws -> CacheRecovery {
        // One that stopped partway finishes instead. Starting another would
        // set aside the new cache it was moving in.
        if let earlier = try finishRecovery(at: url) { return earlier }
        let journal = try prepareRecovery(at: url, setAsideAt: date)
        do {
            try journal.finish(at: url)
        } catch {
            // The journal stays when the new cache moved in or a file
            // couldn't go back, and the next open finishes instead.
            let restored = journal.undo(at: url)
            throw CacheRecoveryError(underlying: error, folder: restored ? nil : journal.folder(at: url))
        }
        return journal.recovery(at: url)
    }

    /// Makes the moves a recovery that stopped partway left, as the journal
    /// beside `url` lists them, and returns what that recovery kept. Nil when
    /// no recovery is unfinished. `open` calls it too, so a caller that
    /// reports the result calls it first.
    public static func finishRecovery(at url: URL) throws -> CacheRecovery? {
        guard let journal = try CacheRecoveryJournal.read(beside: url) else { return nil }
        do {
            try journal.finish(at: url)
        } catch {
            throw CacheRecoveryError(underlying: error, folder: journal.folder(at: url))
        }
        return journal.recovery(at: url)
    }

    /// Builds the new cache with the work read from `url`, creates the
    /// set-aside folder and writes the journal. Nothing moves yet.
    static func prepareRecovery(at url: URL, setAsideAt date: Date) throws -> CacheRecoveryJournal {
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        // Built beside the cache, so moving it in is a rename on one volume.
        let staging = directory.appending(path: ".New Mail Cache \(UUID().uuidString)", directoryHint: .isDirectory)
        var work = SalvagedWork(readingFrom: url)
        let kept: (drafts: Int, changes: Int)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            let queue = try DatabaseQueue(path: staging.appending(path: url.lastPathComponent).path(percentEncoded: false))
            defer { try? queue.close() }
            _ = try MailCache(writer: queue)
            kept = try queue.write { db in try work.write(into: db) }
        } catch {
            try? files.removeItem(at: staging)
            throw CacheRecoveryError(underlying: error)
        }
        do {
            let folder = try makeFolder(named: setAsideFolderName(at: date), in: directory)
            let journal = CacheRecoveryJournal(
                folderName: folder.lastPathComponent, stagingName: staging.lastPathComponent,
                outcome: work.outcome, draftCount: kept.drafts, changeCount: kept.changes
            )
            do {
                try journal.write(beside: url)
            } catch {
                try? files.removeItem(at: folder)
                throw error
            }
            return journal
        } catch {
            try? files.removeItem(at: staging)
            throw CacheRecoveryError(underlying: error)
        }
    }

    /// Creates the folder `name` in `directory`, or the first free numbered
    /// variant of it.
    private static func makeFolder(named name: String, in directory: URL) throws -> URL {
        for number in 1...100 {
            let folder = directory.appending(path: number == 1 ? name : "\(name) \(number)", directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

/// The moves that put a recovered cache in place, written beside the cache
/// (`cache.sqlite-recovery`) before the first one and removed after the
/// last. The old file moves first, which can leave its log beside no
/// database file, and SQLite deletes a log it finds there when it creates a
/// new file. So a launch that finds the journal makes the moves left before
/// SQLite opens anything.
struct CacheRecoveryJournal: Codable {
    /// The set-aside folder and the hidden folder the new cache was built
    /// in, by name in the cache's directory.
    var folderName: String
    var stagingName: String
    var outcome: CacheRecovery.Outcome
    var draftCount: Int
    var changeCount: Int

    static func location(beside url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false) + "-recovery")
    }

    static func read(beside url: URL) throws -> CacheRecoveryJournal? {
        let file = location(beside: url)
        guard exists(file) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func write(beside url: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.location(beside: url), options: .atomic)
    }

    func folder(at url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Where the new cache waits until it moves in.
    func stagedCache(at url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: stagingName, directoryHint: .isDirectory)
            .appending(path: url.lastPathComponent)
    }

    /// The old file, its log, shared memory and rollback journal, each with
    /// its place in the set-aside folder, in the order they move. Left
    /// behind, the log or journal would be applied to the new file.
    func oldFiles(at url: URL) -> [(original: URL, setAside: URL)] {
        ["", "-wal", "-shm", "-journal"].map { suffix in
            (URL(filePath: url.path(percentEncoded: false) + suffix), folder(at: url).appending(path: url.lastPathComponent + suffix))
        }
    }

    func recovery(at url: URL) -> CacheRecovery {
        CacheRecovery(folder: folder(at: url), outcome: outcome, draftCount: draftCount, changeCount: changeCount)
    }

    /// Makes the moves still to make and removes the journal. A file already
    /// moved isn't at its source any more, so finishing again after another
    /// stop repeats nothing. Nothing is replaced: a taken place stops the
    /// moves before the first one and throws, leaving the journal.
    func finish(at url: URL) throws {
        let files = FileManager.default
        let staged = stagedCache(at: url)
        // The new cache moves in last, so once it has, every old file has too.
        if Self.exists(staged) || !Self.exists(url) {
            let left = oldFiles(at: url).filter { Self.exists($0.original) }
            if let taken = left.first(where: { Self.exists($0.setAside) }) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: taken.setAside.path(percentEncoded: false)])
            }
            try files.createDirectory(at: folder(at: url), withIntermediateDirectories: true)
            for file in left { try files.moveItem(at: file.original, to: file.setAside) }
            if Self.exists(staged) { try files.moveItem(at: staged, to: url) }
        }
        try? files.removeItem(at: staged.deletingLastPathComponent())
        try files.removeItem(at: Self.location(beside: url))
    }

    /// Moves the old files back and removes the journal, the new cache and
    /// the empty folder, for a recovery an error stopped before the new cache
    /// moved in. Returns false, keeping the journal so the next open finishes
    /// the recovery instead, when the new cache had moved in or a file
    /// couldn't go back.
    func undo(at url: URL) -> Bool {
        let files = FileManager.default
        let staged = stagedCache(at: url)
        guard Self.exists(staged) else { return false }
        do {
            // A file still at its source never moved, whatever has its place.
            for file in oldFiles(at: url).reversed() where Self.exists(file.setAside) && !Self.exists(file.original) {
                try files.moveItem(at: file.setAside, to: file.original)
            }
            try files.removeItem(at: Self.location(beside: url))
        } catch {
            return false
        }
        try? files.removeItem(at: staged.deletingLastPathComponent())
        let setAside = folder(at: url)
        if (try? files.contentsOfDirectory(atPath: setAside.path(percentEncoded: false)))?.isEmpty == true {
            try? files.removeItem(at: setAside)
        }
        return true
    }

    private static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }
}

/// The unsent work read from a cache file, as raw values under the old
/// tables' column names, so a file left at an older schema still copies.
struct SalvagedWork {
    struct Table {
        var columns: [String] = []
        var rows: [[DatabaseValue]] = []
    }

    /// A row's values by column, read without trusting their types.
    struct Values {
        let values: [String: DatabaseValue]
        func string(_ column: String) -> String? { values[column].flatMap(String.fromDatabaseValue) }
        func int64(_ column: String) -> Int64? { values[column].flatMap(Int64.fromDatabaseValue) }
        func isNull(_ column: String) -> Bool { values[column]?.isNull ?? true }
    }

    static let tableNames = ["localDraft", "outgoingAttachment", "invitationReply", "pendingAction", "unreadDelta"]

    private(set) var tables: [String: Table] = [:]
    private(set) var outcome = CacheRecovery.Outcome.complete

    init(readingFrom url: URL) {
        var configuration = Configuration()
        configuration.readonly = true
        guard let old = try? DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration) else {
            outcome = .unreadable
            return
        }
        var failures = 0
        for name in Self.tableNames {
            var table = Table()
            do {
                try old.read { db in
                    // A cache from before the table has nothing for it.
                    guard try db.tableExists(name) else { return }
                    table.columns = try db.columns(in: name).map(\.name)
                    let list = table.columns.map(\.quotedDatabaseIdentifier).joined(separator: ", ")
                    // A plain scan reads the table itself, never a damaged index.
                    let rows = try Row.fetchCursor(db, sql: "SELECT \(list) FROM \(name.quotedDatabaseIdentifier)")
                    while let row = try rows.next() { table.rows.append(Array(row.databaseValues)) }
                }
            } catch {
                // The rows read before the damage are kept.
                failures += 1
                outcome = .partial
            }
            tables[name] = table
        }
        try? old.close()
        if failures == Self.tableNames.count { outcome = .unreadable }
    }

    /// Writes the rows read into `db`, a new cache, and returns the drafts
    /// and changes it keeps. Rows the app couldn't use stay out: ones it
    /// can't decode, the rows of a draft or change that stayed out, and
    /// changes Gmail already has.
    mutating func write(into db: Database) throws -> (drafts: Int, changes: Int) {
        let drafts = try copy("localDraft", into: db, decode: LocalDraft.init(row:)) { _ in true }
        let draftIDs = Set(drafts.map(\.id))
        let belongsToDraft = { (row: Values) in row.string("localDraftID").map(draftIDs.contains) ?? false }
        _ = try copy("outgoingAttachment", into: db, decode: OutgoingAttachment.init(row:), where: belongsToDraft)
        _ = try copy("invitationReply", into: db, decode: InvitationReplyRecord.init(row:), where: belongsToDraft)
        // A sent change is in the mail Gmail sends again, and an undone one
        // has its inverse queued.
        let actions = try copy("pendingAction", into: db, decode: PendingAction.init(row:)) { row in
            let state = row.string("state")
            guard state != PendingAction.State.sent.rawValue, state != PendingAction.State.undone.rawValue else { return false }
            return row.isNull("localDraftID") || belongsToDraft(row)
        }
        let actionIDs = Set(actions.compactMap(\.id))
        // Gmail's next counts include an accepted change, which ends its deltas.
        _ = try copy("unreadDelta", into: db, decode: { _ in () }) { row in
            row.int64("actionID").map(actionIDs.contains) == true && row.isNull("sentAt")
        }
        // A draft being sent or discarded takes no edits and can't finish
        // without its row, so one whose row stayed out goes back to editing.
        // Whether Gmail was asked to send it stays recorded.
        for draft in drafts where draft.state != .editing {
            let kind: PendingAction.Kind = draft.state == .sending ? .sendDraft : .discardDraft
            guard !actions.contains(where: { $0.localDraftID == draft.id && $0.kind == kind }) else { continue }
            try db.execute(
                sql: "UPDATE localDraft SET state = ?, archiveAfterSend = 0 WHERE id = ?",
                arguments: [LocalDraft.State.editing.rawValue, draft.id]
            )
            outcome = .partial
        }
        return (drafts.count, actions.count { $0.kind.lane != .compose })
    }

    /// Copies the rows of `name` that `keep` accepts into `db`, and returns
    /// what `decode` reads back from each, deleting rows it can't read.
    /// Columns the new table lacks are left out, and ones the old table
    /// lacked take their defaults. A row lost on the way makes the outcome
    /// partial.
    private mutating func copy<Record>(
        _ name: String, into db: Database, decode: (Row) throws -> Record, where keep: (Values) -> Bool
    ) throws -> [Record] {
        guard let table = tables[name], !table.rows.isEmpty else { return [] }
        let newColumns = Set(try db.columns(in: name).map(\.name))
        let shared = table.columns.indices.filter { newColumns.contains(table.columns[$0]) }
        let quoted = name.quotedDatabaseIdentifier
        let insert = try db.makeStatement(sql: """
            INSERT OR IGNORE INTO \(quoted) (\(shared.map { table.columns[$0].quotedDatabaseIdentifier }.joined(separator: ", ")))
            VALUES (\(databaseQuestionMarks(count: shared.count)))
            """)
        var kept: [Record] = []
        for values in table.rows {
            guard keep(Values(values: Dictionary(zip(table.columns, values)) { first, _ in first })) else { continue }
            // A constraint the old file no longer held, such as a duplicate
            // key behind a damaged index, skips the row.
            try insert.execute(arguments: StatementArguments(shared.map { values[$0] }))
            guard db.changesCount > 0 else {
                outcome = .partial
                continue
            }
            let rowID = db.lastInsertedRowID
            guard let stored = try Row.fetchOne(db, sql: "SELECT * FROM \(quoted) WHERE rowid = ?", arguments: [rowID]) else { continue }
            do {
                kept.append(try decode(stored))
            } catch {
                try db.execute(sql: "DELETE FROM \(quoted) WHERE rowid = ?", arguments: [rowID])
                outcome = .partial
            }
        }
        return kept
    }
}
