import Foundation

// Response shapes from the People API (v1), limited to the fields Tern asks
// for: names, email addresses, photos and metadata.

public struct Person: Decodable, Sendable, Equatable {
    public struct FieldMetadata: Decodable, Sendable, Equatable {
        public let primary: Bool?
    }

    public struct Name: Decodable, Sendable, Equatable {
        public let displayName: String?
        public let givenName: String?
        public let familyName: String?
        public let metadata: FieldMetadata?
    }

    public struct EmailAddress: Decodable, Sendable, Equatable {
        public let value: String?
        /// "home", "work", "other" or a custom label.
        public let type: String?
        public let displayName: String?
        public let metadata: FieldMetadata?
    }

    public struct Metadata: Decodable, Sendable, Equatable {
        /// Set on people an incremental sync reports as deleted.
        public let deleted: Bool?
    }

    public struct Photo: Decodable, Sendable, Equatable {
        public let url: String?
        public let isDefault: Bool?
        public let metadata: FieldMetadata?
        enum CodingKeys: String, CodingKey { case url, metadata; case isDefault = "default" }
    }

    /// Stable ID, such as "people/c123" or "otherContacts/c456".
    public let resourceName: String
    public let names: [Name]?
    public let emailAddresses: [EmailAddress]?
    public let metadata: Metadata?
    public let photos: [Photo]?

    public var isDeleted: Bool { metadata?.deleted == true }

    public var photoURL: URL? {
        let values = (photos ?? []).filter { $0.metadata?.primary == true } + (photos ?? [])
        return values.lazy.filter { $0.isDefault != true }.compactMap { $0.url.flatMap(URL.init(string:)) }
            .first { $0.scheme?.lowercased() == "https" && $0.host != nil }
    }

    /// The primary name, else the first one with any text.
    public var displayName: String? {
        let ordered = (names ?? []).filter { $0.metadata?.primary == true } + (names ?? [])
        for name in ordered {
            if let display = name.displayName.nonBlank { return display }
            let parts = [name.givenName.nonBlank, name.familyName.nonBlank].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return nil
    }

    /// Addresses with surrounding spaces removed, the primary first, each once
    /// regardless of case.
    public var addresses: [String] {
        let all = emailAddresses ?? []
        let ordered = all.filter { $0.metadata?.primary == true } + all
        var seen = Set<String>()
        return ordered.compactMap { entry in
            guard let address = entry.value.nonBlank, seen.insert(address.lowercased()).inserted else { return nil }
            return address
        }
    }
}

/// One page of saved contacts or other contacts.
public struct ContactPage: Sendable, Equatable {
    public var people: [Person]
    public var nextPageToken: String?
    /// Present on the last page when a sync token was requested.
    public var nextSyncToken: String?
}

/// Every page of one sync.
public struct ContactSync: Sendable, Equatable {
    /// Changed and deleted people for an incremental sync, everyone for a full one.
    public var people: [Person]
    /// Start the next incremental sync from here. Nil if Google sent none.
    public var syncToken: String?
}

/// One page of directory results.
public struct DirectoryPage: Sendable, Equatable {
    public var people: [Person]
    public var nextPageToken: String?
}

public enum PeopleError: Error, Sendable, Equatable {
    /// Google says the sync token has expired (`EXPIRED_SYNC_TOKEN`). Only a
    /// full sync, without the token, can continue.
    case syncTokenExpired
    /// A request that carried a sync token failed with 400 or 410 without
    /// saying the token expired. It may still have, so the caller decides
    /// whether to run a full sync.
    case syncTokenRejected(status: Int)
    /// The account can't search a directory, which personal accounts lack.
    case directoryUnavailable
}

struct ConnectionsResponse: Decodable {
    let connections: [Person]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

struct OtherContactsResponse: Decodable {
    let otherContacts: [Person]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

struct DirectoryResponse: Decodable {
    let people: [Person]?
    let nextPageToken: String?
}

private extension Optional<String> {
    var nonBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
