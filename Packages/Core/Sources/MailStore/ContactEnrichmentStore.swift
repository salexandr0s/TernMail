import Foundation
import GmailAPI
import GRDB
import MessageContent

extension AccountStore {
    public func observeContactAccess(accountID: String) -> AsyncThrowingStream<Bool, any Error> {
        observeMailConfiguration { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID) else { return false }
            return AccountFeature.named(account.enabledFeatures).contains(.contacts)
        }
    }
}

extension MailCache {
    public func contactPhoto(accountID: String, address: String) async throws -> ContactPhotoRecord? {
        try await read { try $0.contactPhoto(accountID: accountID, address: address) }
    }

    public func observeContactPhoto(accountID: String, address: String) -> AsyncThrowingStream<ContactPhotoRecord?, any Error> {
        observe { try CacheTransaction(db: $0).contactPhoto(accountID: accountID, address: address) }
    }

    @discardableResult
    public func storeContactPhoto(_ data: Data, for expected: ContactPhotoRecord, at date: Date = .now) async throws -> Bool {
        guard !data.isEmpty, data.count <= 1_048_576, date.timeIntervalSince1970.isFinite else { throw MailPreferencesError.invalidRecord }
        return try await write { tx in
            try tx.db.execute(sql: """
                UPDATE contactPhoto SET data = ?,fetchedAt = ? WHERE accountID = ? AND source = ?
                AND resourceName = ? AND url = ? AND version = ?
                """, arguments: [data, date, expected.accountID, expected.source.rawValue, expected.resourceName, expected.url.absoluteString, expected.version])
            let stored = tx.db.changesCount == 1
            if stored { try ContactEnrichmentSQL.trimPhotos(db: tx.db) }
            return stored
        }
    }

    public func contactGroupSuggestions(accountID: String, matching text: String, limit: Int = 5) async throws -> [ContactGroupSuggestion] {
        try await read { tx in
            let pattern = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            guard !pattern.isEmpty else { return [] }
            return try Row.fetchAll(tx.db, sql: """
                SELECT * FROM contactGroup WHERE accountID = ? AND name LIKE ? ESCAPE '\\' COLLATE NOCASE
                ORDER BY name COLLATE NOCASE,resourceName LIMIT ?
                """, arguments: [accountID, pattern + "%", min(20, max(1, limit))]).map {
                    ContactGroupSuggestion(accountID: accountID, resourceName: $0["resourceName"], name: $0["name"],
                        memberCount: $0["memberCount"], isComplete: $0["isComplete"], fetchedAt: $0["fetchedAt"])
                }
        }
    }
}

extension CacheTransaction {
    /// Snapshot photo bytes before replacing contact rows, whose foreign keys clear old references.
    public func applyEnrichedContactSync(_ people: [Person], source: ContactSource, syncToken: String?, fields: String,
        isFullSync: Bool, now: Date, accountID: String
    ) throws {
        let old = try Row.fetchAll(db, sql: "SELECT * FROM contactPhoto WHERE accountID = ? AND source = ?",
            arguments: [accountID, source.rawValue]).map(ContactEnrichmentSQL.photo)
        let previous = Dictionary(old.map { ($0.resourceName, $0) }, uniquingKeysWith: { first, _ in first })
        try applyContactSync(people, source: source, syncToken: syncToken, fields: fields, isFullSync: isFullSync, now: now, accountID: accountID)
        if source == .connection {
            try db.execute(sql: "INSERT OR IGNORE INTO contactEnrichmentGeneration (accountID,source,generation) VALUES (?,?,?)",
                arguments: [accountID, source.rawValue, UUID().uuidString])
        }
        for person in people where !person.isDeleted && !person.addresses.isEmpty {
            guard let url = person.photoURL else { continue }
            let kept = previous[person.resourceName].flatMap { $0.url == url ? $0 : nil }
            try db.execute(sql: """
                INSERT INTO contactPhoto (accountID,source,resourceName,url,version,data,fetchedAt) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(accountID,source,resourceName) DO UPDATE SET url=excluded.url,version=excluded.version,
                data=excluded.data,fetchedAt=excluded.fetchedAt
                """, arguments: [accountID, source.rawValue, person.resourceName, url.absoluteString, UUID().uuidString, kept?.data, kept?.fetchedAt])
        }
    }

    public func contactPhoto(accountID: String, address: String) throws -> ContactPhotoRecord? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.* FROM contactPhoto p JOIN contactEmail e
            ON e.accountID=p.accountID AND e.source=p.source AND e.resourceName=p.resourceName
            WHERE p.accountID = ? AND e.lowercasedAddress = ?
            ORDER BY CASE p.source WHEN 'connection' THEN 0 ELSE 1 END,p.resourceName LIMIT 1
            """, arguments: [accountID, EmailAddress(address: address).normalized]) else { return nil }
        return try ContactEnrichmentSQL.photo(row)
    }

    public func contactEnrichmentGeneration(accountID: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT generation FROM contactEnrichmentGeneration WHERE accountID = ?", arguments: [accountID])
    }

    public func replaceContactGroups(_ catalog: ContactGroupCatalog, accountID: String, at date: Date) throws {
        guard catalog.groups.count <= PeopleClient.maximumGroups else { throw MailPreferencesError.invalidRecord }
        guard try contactSync(source: .connection, accountID: accountID) != nil else { return }
        try db.execute(sql: "DELETE FROM contactGroup WHERE accountID = ?", arguments: [accountID])
        for group in catalog.groups where group.isUserGroup {
            guard let name = group.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try db.execute(sql: """
                INSERT INTO contactGroup (accountID,source,resourceName,name,memberCount,isComplete,fetchedAt) VALUES (?,?,?,?,?,?,?)
                """, arguments: [accountID, ContactSource.connection.rawValue, group.resourceName, name,
                    max(0, group.memberCount ?? 0), catalog.isComplete, date])
        }
    }
}

enum ContactEnrichmentSQL {
    static func photo(_ row: Row) throws -> ContactPhotoRecord {
        let rawURL: String = row["url"]
        let rawSource: String = row["source"]
        guard let url = URL(string: rawURL), let source = ContactSource(rawValue: rawSource) else { throw MailPreferencesError.invalidRecord }
        return ContactPhotoRecord(accountID: row["accountID"], source: source, resourceName: row["resourceName"], url: url,
            version: row["version"], data: row["data"], fetchedAt: row["fetchedAt"])
    }

    static func trimPhotos(db: Database) throws {
        var used = 0
        for row in try Row.fetchAll(db, sql: "SELECT accountID,source,resourceName,length(data) AS bytes FROM contactPhoto WHERE data IS NOT NULL ORDER BY fetchedAt DESC") {
            let bytes: Int = row["bytes"]
            used += bytes
            if used > 64 * 1_024 * 1_024 {
                try db.execute(sql: "UPDATE contactPhoto SET data=NULL,fetchedAt=NULL WHERE accountID=? AND source=? AND resourceName=?",
                    arguments: [row["accountID"], row["source"], row["resourceName"]])
            }
        }
    }
}
