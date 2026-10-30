import Foundation
import MessageContent

public struct ContactPhotoRecord: Sendable, Equatable {
    public var accountID: String
    public var source: ContactSource
    public var resourceName: String
    public var url: URL
    public var version: String
    public var data: Data?
    public var fetchedAt: Date?

    public init(accountID: String, source: ContactSource, resourceName: String, url: URL, version: String = UUID().uuidString,
                data: Data? = nil, fetchedAt: Date? = nil) {
        self.accountID = accountID; self.source = source; self.resourceName = resourceName; self.url = url
        self.version = version; self.data = data; self.fetchedAt = fetchedAt
    }
}

public struct ContactGroupSuggestion: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let resourceName: String
    public let name: String
    public let memberCount: Int
    public let isComplete: Bool
    public let fetchedAt: Date
    public var id: String { accountID + "/" + resourceName }

    public init(accountID: String, resourceName: String, name: String, memberCount: Int, isComplete: Bool = true, fetchedAt: Date = .now) {
        self.accountID = accountID; self.resourceName = resourceName; self.name = name
        self.memberCount = memberCount; self.isComplete = isComplete; self.fetchedAt = fetchedAt
    }
}

public struct ContactGroupExpansion: Sendable, Equatable {
    public let group: ContactGroupSuggestion
    public let recipients: [EmailAddress]
    public let missingMemberResourceNames: [String]
    public let invalidAddressCount: Int
    public let didTruncate: Bool
    public var isComplete: Bool { !didTruncate && missingMemberResourceNames.isEmpty && invalidAddressCount == 0 && !recipients.isEmpty }

    public init(group: ContactGroupSuggestion, recipients: [EmailAddress], missingMemberResourceNames: [String] = [],
                invalidAddressCount: Int = 0, didTruncate: Bool = false) {
        self.group = group; self.recipients = recipients; self.missingMemberResourceNames = missingMemberResourceNames
        self.invalidAddressCount = invalidAddressCount; self.didTruncate = didTruncate
    }
}
