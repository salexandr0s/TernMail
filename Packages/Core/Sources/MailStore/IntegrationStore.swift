import Foundation
import GmailAPI
import GRDB
import MessageContent

// MARK: Identities

/// An address an account can send as, as `sendAs.list` last returned it.
/// Kept in `config.sqlite` and deleted with its account.
public struct IdentityRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sendAsIdentity"

    public var accountID: String
    /// As Gmail returns it.
    public var address: String
    public var lowercasedAddress: String
    /// Nil when Gmail has none, and the account's own name applies.
    public var displayName: String?
    public var replyTo: String?
    public var signatureHTML: String?
    public var isPrimary: Bool
    public var isDefault: Bool
    public var treatAsAlias: Bool
    public var verificationStatus: SendAsIdentity.VerificationStatus
    public var fetchedAt: Date

    public init(
        accountID: String, address: String, displayName: String? = nil, replyTo: String? = nil,
        signatureHTML: String? = nil, isPrimary: Bool = false, isDefault: Bool = false, treatAsAlias: Bool = false,
        verificationStatus: SendAsIdentity.VerificationStatus = .unspecified, fetchedAt: Date
    ) {
        self.accountID = accountID
        self.address = address
        lowercasedAddress = address.lowercased()
        // Gmail sends empty strings for unset values.
        self.displayName = displayName.nonBlank
        self.replyTo = replyTo.nonBlank
        self.signatureHTML = signatureHTML.nonBlank
        self.isPrimary = isPrimary
        self.isDefault = isDefault
        self.treatAsAlias = treatAsAlias
        self.verificationStatus = verificationStatus
        self.fetchedAt = fetchedAt
    }

    public init(_ identity: SendAsIdentity, accountID: String, fetchedAt: Date) {
        self.init(
            accountID: accountID, address: identity.sendAsEmail, displayName: identity.displayName,
            replyTo: identity.replyToAddress, signatureHTML: identity.signature, isPrimary: identity.isPrimary,
            isDefault: identity.isDefault, treatAsAlias: identity.treatAsAlias,
            verificationStatus: identity.verificationStatus, fetchedAt: fetchedAt
        )
    }

    /// Whether Gmail lets the account send as this address.
    public var canSend: Bool { isPrimary || verificationStatus == .accepted }
}

extension AccountStore {
    /// The account's identities, the primary address first, then by address.
    public func identities(accountID: String) async throws -> [IdentityRecord] {
        try await writer.read { db in
            try IdentityRecord
                .filter(Column("accountID") == accountID)
                .order(Column("isPrimary").desc, Column("lowercasedAddress"))
                .fetchAll(db)
        }
    }

    /// Replaces the account's identities with one `sendAs.list` answer.
    public func replaceIdentities(_ identities: [SendAsIdentity], accountID: String, fetchedAt: Date) async throws {
        let records = identities.map { IdentityRecord($0, accountID: accountID, fetchedAt: fetchedAt) }
        try await writer.write { db in
            for record in records {
                try record.upsert(db)
            }
            let kept = records.map(\.lowercasedAddress)
            _ = try IdentityRecord
                .filter(Column("accountID") == accountID && !kept.contains(Column("lowercasedAddress")))
                .deleteAll(db)
        }
    }

    /// Records a signature Gmail accepted for one of the account's addresses.
    public func setSignature(_ html: String?, address: String, accountID: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE sendAsIdentity SET signatureHTML = ? WHERE accountID = ? AND lowercasedAddress = ?",
                arguments: [html.nonBlank, accountID, address.lowercased()]
            )
        }
    }

    /// Changes one account in a single write, so a concurrent change to
    /// another of its columns isn't lost. Returns nil when the account is gone.
    @discardableResult
    public func updateAccount(
        id: String, _ change: @escaping @Sendable (inout AccountRecord) -> Void
    ) async throws -> AccountRecord? {
        try await writer.write { db in
            guard var account = try AccountRecord.fetchOne(db, key: id) else { return nil }
            change(&account)
            try account.update(db)
            return account
        }
    }
}

// MARK: Contacts

/// Where a synced contact comes from.
public enum ContactSource: String, Codable, Sendable, CaseIterable {
    /// Saved contacts, from `people.connections.list`.
    case connection
    /// People the user has written to, from `otherContacts.list`.
    case other
}

/// A person with at least one address. The addresses are in `contactEmail`.
struct ContactRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contact"

    var accountID: String
    var source: ContactSource
    var resourceName: String
    var displayName: String?
    var updatedAt: Date
}

struct ContactEmailRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contactEmail"

    var accountID: String
    var source: ContactSource
    var resourceName: String
    var lowercasedAddress: String
    var address: String
    var isPrimary: Bool
}

/// How far one source's contacts are synced.
public struct ContactSyncRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "contactSync"

    public var accountID: String
    public var source: ContactSource
    /// Nil when Google returned none, so the next sync is a full one.
    public var syncToken: String?
    /// The `personFields` or `readMask` the token was issued for.
    public var fields: String
    public var lastFullSyncAt: Date
}

extension CacheTransaction {
    public func contactSync(source: ContactSource, accountID: String) throws -> ContactSyncRecord? {
        try ContactSyncRecord.fetchOne(db, key: ["accountID": accountID, "source": source.rawValue])
    }

    /// Applies one whole sync of `source` with the token from its last page,
    /// so a stored token never skips a page. A full sync replaces the
    /// source's contacts, and an incremental one replaces the people it lists.
    /// People deleted in Google or left without an address are removed.
    public func applyContactSync(
        _ people: [Person], source: ContactSource, syncToken: String?, fields: String,
        isFullSync: Bool, now: Date, accountID: String
    ) throws {
        if isFullSync {
            try ContactRecord.filter(Column("accountID") == accountID && Column("source") == source.rawValue).deleteAll(db)
        }
        for person in people {
            // The emails go with the row.
            try ContactRecord.deleteOne(
                db, key: ["accountID": accountID, "source": source.rawValue, "resourceName": person.resourceName]
            )
            let addresses = person.addresses
            guard !person.isDeleted, !addresses.isEmpty else { continue }
            try ContactRecord(
                accountID: accountID, source: source, resourceName: person.resourceName,
                displayName: person.displayName, updatedAt: now
            ).insert(db)
            for (index, address) in addresses.enumerated() {
                // `addresses` puts the primary first and lists each once.
                try ContactEmailRecord(
                    accountID: accountID, source: source, resourceName: person.resourceName,
                    lowercasedAddress: address.lowercased(), address: address, isPrimary: index == 0
                ).insert(db)
            }
        }
        let lastFullSyncAt = isFullSync ? now : try contactSync(source: source, accountID: accountID)?.lastFullSyncAt
        try ContactSyncRecord(
            accountID: accountID, source: source, syncToken: syncToken, fields: fields,
            // Without a record of a full sync, the next check runs one.
            lastFullSyncAt: lastFullSyncAt ?? .distantPast
        ).upsert(db)
    }

    /// Removes the account's contacts and sync state, as when Contacts is turned off.
    public func deleteContacts(accountID: String) throws {
        for table in ["contactEmail", "contact", "contactSync"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ?", arguments: [accountID])
        }
    }
}

// MARK: Invitations

/// The invitation in one cached message's calendar part.
public struct MessageCalendarRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageCalendar"

    public var accountID: String
    public var messageID: String
    public var uid: String
    /// Empty for the whole event. See `Invitation.recurrenceKey`.
    public var recurrenceKey: String
    public var sequence: Int
    /// DTSTAMP.
    public var stamp: Date?
    /// METHOD in upper case. Nil when the object has none.
    public var method: String?
    public var invitation: Invitation

    public init(accountID: String, messageID: String, invitation: Invitation) {
        self.accountID = accountID
        self.messageID = messageID
        uid = invitation.uid
        recurrenceKey = invitation.recurrenceKey
        sequence = invitation.sequence
        stamp = invitation.stamp
        method = switch invitation.method {
        case .request?: "REQUEST"
        case .cancel?: "CANCEL"
        case .reply?: "REPLY"
        case .other(let name)?: name
        case nil: nil
        }
        self.invitation = invitation
    }

    /// Whether `other` is a later version of the same event: a higher
    /// SEQUENCE, or the same one with a later DTSTAMP (RFC 5546).
    public func isOlder(than other: MessageCalendarRecord) -> Bool {
        (sequence, stamp ?? .distantPast) < (other.sequence, other.stamp ?? .distantPast)
    }

    /// Methods attendees send. They answer a version rather than being one.
    static let attendeeMethods = ["REPLY", "COUNTER", "REFRESH"]
}

/// The answer the user last queued for an event. It outlives its draft, so
/// the banner keeps showing it after the send.
public struct InvitationReplyRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "invitationReply"

    public var accountID: String
    public var uid: String
    public var recurrenceKey: String
    public var participationStatus: Invitation.ParticipationStatus
    public var localDraftID: String
    public var queuedAt: Date

    public init(
        accountID: String, uid: String, recurrenceKey: String,
        participationStatus: Invitation.ParticipationStatus, localDraftID: String, queuedAt: Date
    ) {
        self.accountID = accountID
        self.uid = uid
        self.recurrenceKey = recurrenceKey
        self.participationStatus = participationStatus
        self.localDraftID = localDraftID
        self.queuedAt = queuedAt
    }
}

extension CacheTransaction {
    /// Stores the invitation found in a message, replacing an earlier one.
    public func saveMessageCalendar(_ record: MessageCalendarRecord) throws {
        try record.upsert(db)
    }

    public func messageCalendar(messageID: String, accountID: String) throws -> MessageCalendarRecord? {
        try MessageCalendarRecord.fetchOne(db, key: ["accountID": accountID, "messageID": messageID])
    }

    /// The newest version of an event across the account's cached mail: the
    /// highest SEQUENCE, then the latest DTSTAMP. Copies of one version tie,
    /// so compare with `isOlder(than:)` rather than by message.
    public func latestInvitation(uid: String, recurrenceKey: String, accountID: String) throws -> MessageCalendarRecord? {
        try MessageCalendarRecord
            .filter(Column("accountID") == accountID && Column("uid") == uid && Column("recurrenceKey") == recurrenceKey)
            .filter(Column("method") == nil || !MessageCalendarRecord.attendeeMethods.contains(Column("method")))
            .order(Column("sequence").desc, Column("stamp").desc, Column("messageID"))
            .fetchOne(db)
    }

    /// Records the answer queued for an event, replacing an earlier one.
    public func saveInvitationReply(_ reply: InvitationReplyRecord) throws {
        try reply.upsert(db)
    }

    public func invitationReply(uid: String, recurrenceKey: String, accountID: String) throws -> InvitationReplyRecord? {
        try InvitationReplyRecord.fetchOne(db, key: ["accountID": accountID, "uid": uid, "recurrenceKey": recurrenceKey])
    }

    /// Removes the answer an undone send had queued. A later answer to the
    /// same event, from another draft, stays. Returns whether a row went.
    @discardableResult
    public func deleteInvitationReply(localDraftID: String, accountID: String) throws -> Bool {
        try InvitationReplyRecord
            .filter(Column("accountID") == accountID && Column("localDraftID") == localDraftID)
            .deleteAll(db) > 0
    }
}

private extension Optional<String> {
    var nonBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
