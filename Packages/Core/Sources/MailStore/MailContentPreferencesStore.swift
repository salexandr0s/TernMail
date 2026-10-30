import Foundation
import GRDB
import MessageContent

extension AccountStore {
    public func savedMailSearches() async throws -> [SavedMailSearch] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mailSavedSearch ORDER BY sortOrder,name,id").map { row in
                let id: String = row["id"]
                return try SavedMailSearch(id: id, name: row["name"], query: row["query"],
                    scope: MailContentPreferencesSQL.scope(all: row["allAccounts"], table: "mailSavedSearchAccount", key: "searchID", id: id, db: db),
                    sortOrder: row["sortOrder"])
            }
        }
    }

    public func saveSavedMailSearch(_ search: SavedMailSearch) async throws {
        guard MailPreferencesSQL.nonblank(search.id), MailPreferencesSQL.nonblank(search.name), MailPreferencesSQL.nonblank(search.query) else {
            throw MailPreferencesError.invalidRecord
        }
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO mailSavedSearch (id,name,query,allAccounts,sortOrder) VALUES (?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,query=excluded.query,
                allAccounts=excluded.allAccounts,sortOrder=excluded.sortOrder
                """, arguments: [search.id, search.name, search.query, search.scope == .allAccounts, search.sortOrder])
            try MailContentPreferencesSQL.saveScope(search.scope, table: "mailSavedSearchAccount", key: "searchID", id: search.id, db: db)
        }
    }

    public func deleteSavedMailSearch(id: String) async throws {
        try await writer.write { try $0.execute(sql: "DELETE FROM mailSavedSearch WHERE id = ?", arguments: [id]) }
    }

    public func mailFavorites() async throws -> [MailFavorite] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mailFavorite ORDER BY sortOrder,id").map { row in
                let id: String = row["id"]
                let kind: String = row["kind"]
                let target: MailFavoriteTarget
                switch kind {
                case "mailbox":
                    guard let label: String = row["labelID"] else { throw MailPreferencesError.invalidRecord }
                    target = .mailbox(labelID: label, scope: try MailContentPreferencesSQL.scope(all: row["allAccounts"],
                        table: "mailFavoriteAccount", key: "favoriteID", id: id, db: db))
                case "label":
                    guard let accountID: String = row["accountID"], let label: String = row["labelID"] else { throw MailPreferencesError.invalidRecord }
                    target = .label(accountID: accountID, labelID: label)
                case "search":
                    guard let searchID: String = row["savedSearchID"] else { throw MailPreferencesError.invalidRecord }
                    target = .savedSearch(id: searchID)
                default: throw MailPreferencesError.invalidRecord
                }
                return MailFavorite(id: id, target: target, sortOrder: row["sortOrder"])
            }
        }
    }

    public func saveMailFavorites(_ ordered: [MailFavorite]) async throws {
        try await writer.write { try MailContentPreferencesSQL.saveFavorites(ordered, db: $0) }
    }

    public func resetMailFavorites() async throws { try await saveMailFavorites(MailFavorite.defaults) }

    public func composeTemplates() async throws -> [ComposeTemplate] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM composeTemplate ORDER BY sortOrder,name,id").map { row in
                try ComposeTemplate(id: row["id"], name: row["name"],
                    document: MailPreferencesSQL.decode(ComposeDocument.self, row["document"]), sortOrder: row["sortOrder"])
            }
        }
    }

    public func saveComposeTemplate(_ template: ComposeTemplate) async throws {
        try await saveDocument(table: "composeTemplate", id: template.id, name: template.name, document: template.document, sortOrder: template.sortOrder)
    }

    public func deleteComposeTemplate(id: String) async throws {
        try await writer.write { try $0.execute(sql: "DELETE FROM composeTemplate WHERE id = ?", arguments: [id]) }
    }

    public func localSignatures() async throws -> [LocalSignature] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM localSignature ORDER BY sortOrder,name,id").map { row in
                try LocalSignature(id: row["id"], name: row["name"],
                    document: MailPreferencesSQL.decode(ComposeDocument.self, row["document"]), sortOrder: row["sortOrder"])
            }
        }
    }

    public func saveLocalSignature(_ signature: LocalSignature) async throws {
        try await saveDocument(table: "localSignature", id: signature.id, name: signature.name, document: signature.document, sortOrder: signature.sortOrder)
    }

    public func deleteLocalSignature(id: String) async throws {
        try await writer.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT * FROM signatureAssignment") {
                var assignment = try MailContentPreferencesSQL.assignment(row)
                guard assignment.newMessages == .local(id: id) || assignment.replies == .local(id: id) else { continue }
                if assignment.newMessages == .local(id: id) { assignment.newMessages = .none }
                if assignment.replies == .local(id: id) { assignment.replies = .none }
                try MailContentPreferencesSQL.saveAssignment(assignment, db: db)
            }
            try db.execute(sql: "DELETE FROM localSignature WHERE id = ?", arguments: [id])
        }
    }

    public func signatureAssignments(accountID: String) async throws -> [SignatureAssignment] {
        try await writer.read { db in
            try MailPreferencesSQL.requireAccount(accountID, db: db)
            return try Row.fetchAll(db, sql: "SELECT * FROM signatureAssignment WHERE accountID = ? ORDER BY address", arguments: [accountID])
                .map(MailContentPreferencesSQL.assignment)
        }
    }

    public func saveSignatureAssignment(_ assignment: SignatureAssignment) async throws {
        var normalized = assignment
        normalized.address = normalized.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.address.isEmpty || EmailAddress(address: normalized.address).isValid else { throw MailPreferencesError.invalidRecord }
        let value = normalized
        try await writer.write { db in
            try MailPreferencesSQL.requireAccount(value.accountID, db: db)
            for selection in [value.newMessages, value.replies] {
                if case .local(let id) = selection,
                   try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM localSignature WHERE id = ?)", arguments: [id]) != true {
                    throw MailPreferencesError.missingReference
                }
            }
            try MailContentPreferencesSQL.saveAssignment(value, db: db)
        }
    }

    private func saveDocument(table: String, id: String, name: String, document: ComposeDocument, sortOrder: Int) async throws {
        guard MailPreferencesSQL.nonblank(id), MailPreferencesSQL.nonblank(name) else { throw MailPreferencesError.invalidRecord }
        let encoded = try MailPreferencesSQL.encode(document)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO \(table) (id,name,document,sortOrder) VALUES (?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,document=excluded.document,sortOrder=excluded.sortOrder
                """, arguments: [id, name, encoded, sortOrder])
        }
    }
}

enum MailContentPreferencesSQL {
    static func scope(all: Bool, table: String, key: String, id: String, db: Database) throws -> MailSearchScope {
        if all { return .allAccounts }
        return .accounts(try String.fetchAll(db, sql: "SELECT accountID FROM \(table) WHERE \(key) = ? ORDER BY accountID", arguments: [id]))
    }

    static func saveScope(_ scope: MailSearchScope, table: String, key: String, id: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE \(key) = ?", arguments: [id])
        if case .accounts(let accountIDs) = scope {
            for accountID in Set(accountIDs).sorted() {
                try MailPreferencesSQL.requireAccount(accountID, db: db)
                try db.execute(sql: "INSERT INTO \(table) (\(key),accountID) VALUES (?,?)", arguments: [id, accountID])
            }
        }
    }

    static func saveFavorites(_ ordered: [MailFavorite], db: Database) throws {
        guard Set(ordered.map(\.id)).count == ordered.count, ordered.allSatisfy({ MailPreferencesSQL.nonblank($0.id) }) else {
            throw MailPreferencesError.invalidRecord
        }
        try db.execute(sql: "DELETE FROM mailFavorite")
        for (index, favorite) in ordered.enumerated() {
            switch favorite.target {
            case .mailbox(let labelID, let scope):
                guard MailPreferencesSQL.nonblank(labelID) else { throw MailPreferencesError.invalidRecord }
                try db.execute(sql: "INSERT INTO mailFavorite (id,kind,labelID,allAccounts,sortOrder) VALUES (?,'mailbox',?,?,?)",
                    arguments: [favorite.id, labelID, scope == .allAccounts, index])
                try saveScope(scope, table: "mailFavoriteAccount", key: "favoriteID", id: favorite.id, db: db)
            case .label(let accountID, let labelID):
                guard MailPreferencesSQL.nonblank(labelID) else { throw MailPreferencesError.invalidRecord }
                try MailPreferencesSQL.requireAccount(accountID, db: db)
                try db.execute(sql: "INSERT INTO mailFavorite (id,kind,labelID,accountID,sortOrder) VALUES (?,'label',?,?,?)",
                    arguments: [favorite.id, labelID, accountID, index])
            case .savedSearch(let searchID):
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mailSavedSearch WHERE id = ?)", arguments: [searchID]) == true else {
                    throw MailPreferencesError.missingReference
                }
                try db.execute(sql: "INSERT INTO mailFavorite (id,kind,savedSearchID,sortOrder) VALUES (?,'search',?,?)",
                    arguments: [favorite.id, searchID, index])
            }
        }
    }

    static func assignment(_ row: Row) throws -> SignatureAssignment {
        try SignatureAssignment(accountID: row["accountID"], address: row["address"],
            newMessages: MailPreferencesSQL.decode(SignatureSelection.self, row["newMessages"]),
            replies: MailPreferencesSQL.decode(SignatureSelection.self, row["replies"]),
            placeAboveQuote: row["placeAboveQuote"], includeSeparator: row["includeSeparator"])
    }

    static func saveAssignment(_ value: SignatureAssignment, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO signatureAssignment (accountID,address,newMessages,replies,placeAboveQuote,includeSeparator) VALUES (?,?,?,?,?,?)
            ON CONFLICT(accountID,address) DO UPDATE SET newMessages=excluded.newMessages,replies=excluded.replies,
            placeAboveQuote=excluded.placeAboveQuote,includeSeparator=excluded.includeSeparator
            """, arguments: [value.accountID, value.address, try MailPreferencesSQL.encode(value.newMessages),
                try MailPreferencesSQL.encode(value.replies), value.placeAboveQuote, value.includeSeparator])
    }
}
