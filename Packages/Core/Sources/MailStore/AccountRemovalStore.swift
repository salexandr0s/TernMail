import Foundation
import GRDB

/// This record has no account foreign key: it must survive account deletion.
public struct PendingAccountRemoval: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, CaseIterable, Sendable {
        case account, credentials, cache, files, writingStyle
    }

    public let accountID: String
    public let generation: String
    public var draftIDs: Set<String>
    public var completed: Set<Stage>

    public static func validPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !value.contains("/") && !value.contains(":") && !value.contains("\\")
    }
}

public enum AccountRemovalError: Error, LocalizedError, Sendable {
    case invalidRecord, incomplete

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "Tern could not read the pending account cleanup."
        case .incomplete: "Some local account data could not be removed. Tern will retry at the next launch."
        }
    }
}

enum AccountRemovalSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("account-removal-v1") { db in
            try db.create(table: "pendingAccountRemoval") { t in
                t.primaryKey("accountID", .text)
                t.column("generation", .text).notNull()
                t.column("draftIDs", .jsonText).notNull()
                t.column("completed", .jsonText).notNull()
            }
        }
    }
}

extension AccountStore {
    public func pendingAccountRemovals() async throws -> [PendingAccountRemoval] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pendingAccountRemoval ORDER BY accountID").map(Self.removal)
        }
    }

    /// Checkpoint every file identity before deleting rows that lead to it.
    public func beginAccountRemoval(accountID: String, draftIDs: Set<String>) async throws -> PendingAccountRemoval {
        guard PendingAccountRemoval.validPathComponent(accountID), draftIDs.allSatisfy(PendingAccountRemoval.validPathComponent) else {
            throw AccountRemovalError.invalidRecord
        }
        return try await writer.write { db in
            var removal: PendingAccountRemoval
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM pendingAccountRemoval WHERE accountID = ?", arguments: [accountID]) {
                removal = try Self.removal(row)
                if !draftIDs.isSubset(of: removal.draftIDs) {
                    removal.draftIDs.formUnion(draftIDs)
                    removal.completed.subtract([.cache, .files])
                }
            } else {
                removal = PendingAccountRemoval(accountID: accountID, generation: UUID().uuidString,
                    draftIDs: draftIDs, completed: [])
            }
            try db.execute(sql: """
                INSERT INTO pendingAccountRemoval(accountID,generation,draftIDs,completed) VALUES (?,?,?,?)
                ON CONFLICT(accountID) DO UPDATE SET draftIDs=excluded.draftIDs,completed=excluded.completed
                """, arguments: [removal.accountID, removal.generation,
                    try Self.removalJSON(removal.draftIDs.sorted()), try Self.removalJSON(removal.completed.map(\.rawValue).sorted())])
            return removal
        }
    }

    public func completeAccountRemovalStage(_ stage: PendingAccountRemoval.Stage, removal: PendingAccountRemoval) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT * FROM pendingAccountRemoval WHERE accountID = ? AND generation = ?",
                arguments: [removal.accountID, removal.generation]) else { throw AccountRemovalError.invalidRecord }
            var current = try Self.removal(row)
            current.completed.insert(stage)
            try db.execute(sql: "UPDATE pendingAccountRemoval SET completed = ? WHERE accountID = ? AND generation = ?",
                arguments: [try Self.removalJSON(current.completed.map(\.rawValue).sorted()), current.accountID, current.generation])
        }
    }

    public func finishAccountRemoval(_ removal: PendingAccountRemoval) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT * FROM pendingAccountRemoval WHERE accountID = ? AND generation = ?",
                arguments: [removal.accountID, removal.generation]),
                  try Self.removal(row).completed == Set(PendingAccountRemoval.Stage.allCases) else {
                throw AccountRemovalError.incomplete
            }
            try db.execute(sql: "DELETE FROM pendingAccountRemoval WHERE accountID = ? AND generation = ?",
                arguments: [removal.accountID, removal.generation])
        }
    }

    private static func removal(_ row: Row) throws -> PendingAccountRemoval {
        let accountID: String = row["accountID"]
        let generation: String = row["generation"]
        let draftJSON: String = row["draftIDs"]
        let completedJSON: String = row["completed"]
        let drafts = try JSONDecoder().decode(Set<String>.self, from: Data(draftJSON.utf8))
        let completed = try JSONDecoder().decode(Set<PendingAccountRemoval.Stage>.self, from: Data(completedJSON.utf8))
        guard PendingAccountRemoval.validPathComponent(accountID), UUID(uuidString: generation) != nil,
              drafts.allSatisfy(PendingAccountRemoval.validPathComponent) else { throw AccountRemovalError.invalidRecord }
        return PendingAccountRemoval(accountID: accountID, generation: generation, draftIDs: drafts, completed: completed)
    }

    private static func removalJSON(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
