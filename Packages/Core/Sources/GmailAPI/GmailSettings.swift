import Foundation

// Gmail settings resources (`users.settings`, v1). Fields Gmail may omit are
// optional or fall back to Gmail's documented default.

/// A Gmail filter. Gmail has no update call, so changing a filter means
/// creating a new one and deleting the old.
public struct GmailFilter: Codable, Sendable, Equatable {
    public struct Criteria: Codable, Sendable, Equatable {
        public var from: String?
        public var to: String?
        public var subject: String?
        /// Gmail search syntax.
        public var query: String?
        public var negatedQuery: String?
        public var hasAttachment: Bool?
        public var excludeChats: Bool?
        /// Bytes, compared with `sizeComparison`.
        public var size: Int?
        public var sizeComparison: SizeComparison?

        public init(
            from: String? = nil, to: String? = nil, subject: String? = nil,
            query: String? = nil, negatedQuery: String? = nil,
            hasAttachment: Bool? = nil, excludeChats: Bool? = nil,
            size: Int? = nil, sizeComparison: SizeComparison? = nil
        ) {
            self.from = from
            self.to = to
            self.subject = subject
            self.query = query
            self.negatedQuery = negatedQuery
            self.hasAttachment = hasAttachment
            self.excludeChats = excludeChats
            self.size = size
            self.sizeComparison = sizeComparison
        }
    }

    public struct Action: Codable, Sendable, Equatable {
        public var addLabelIds: [String]?
        public var removeLabelIds: [String]?
        /// A forwarding address, which Gmail accepts only once it is verified.
        public var forward: String?

        public init(addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil, forward: String? = nil) {
            self.addLabelIds = addLabelIds
            self.removeLabelIds = removeLabelIds
            self.forward = forward
        }
    }

    public enum SizeComparison: String, Codable, Sendable {
        case unspecified, smaller, larger

        /// A value Gmail adds later reads as `unspecified` rather than failing the list.
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = SizeComparison(rawValue: value) ?? .unspecified
        }
    }

    /// Nil only for a filter that hasn't reached Gmail.
    public var id: String?
    public var criteria: Criteria
    public var action: Action

    public init(id: String? = nil, criteria: Criteria, action: Action) {
        self.id = id
        self.criteria = criteria
        self.action = action
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        criteria = try container.decodeIfPresent(Criteria.self, forKey: .criteria) ?? Criteria()
        action = try container.decodeIfPresent(Action.self, forKey: .action) ?? Action()
    }

    /// Whether two filters match the same mail and do the same thing, ignoring
    /// the ID, surrounding spaces, label order, and unset values written as
    /// empty, false or `unspecified`.
    public func hasSameRules(as other: GmailFilter) -> Bool {
        criteria.normalized == other.criteria.normalized && action.normalized == other.action.normalized
    }
}

extension GmailFilter.Criteria {
    var normalized: GmailFilter.Criteria {
        GmailFilter.Criteria(
            from: from.trimmedNonEmpty,
            to: to.trimmedNonEmpty,
            subject: subject.trimmedNonEmpty,
            query: query.trimmedNonEmpty,
            negatedQuery: negatedQuery.trimmedNonEmpty,
            hasAttachment: hasAttachment == true ? true : nil,
            excludeChats: excludeChats == true ? true : nil,
            size: size,
            sizeComparison: sizeComparison == .unspecified ? nil : sizeComparison
        )
    }
}

extension GmailFilter.Action {
    var normalized: GmailFilter.Action {
        GmailFilter.Action(
            addLabelIds: addLabelIds.sortedNonEmpty,
            removeLabelIds: removeLabelIds.sortedNonEmpty,
            forward: forward.trimmedNonEmpty
        )
    }
}

private extension Optional<String> {
    var trimmedNonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private extension Optional<[String]> {
    var sortedNonEmpty: [String]? {
        guard let self, !self.isEmpty else { return nil }
        return Array(Set(self)).sorted()
    }
}

/// The vacation responder. Gmail stores its times as epoch milliseconds in strings.
public struct VacationSettings: Codable, Sendable, Equatable {
    public var enableAutoReply: Bool
    public var responseSubject: String?
    public var responseBodyPlainText: String?
    /// Used instead of the plain text when both are set. Gmail sanitizes it.
    public var responseBodyHtml: String?
    public var restrictToContacts: Bool
    /// Workspace accounts only.
    public var restrictToDomain: Bool
    public var startTime: Date?
    public var endTime: Date?

    public init(
        enableAutoReply: Bool = false,
        responseSubject: String? = nil,
        responseBodyPlainText: String? = nil,
        responseBodyHtml: String? = nil,
        restrictToContacts: Bool = false,
        restrictToDomain: Bool = false,
        startTime: Date? = nil,
        endTime: Date? = nil
    ) {
        self.enableAutoReply = enableAutoReply
        self.responseSubject = responseSubject
        self.responseBodyPlainText = responseBodyPlainText
        self.responseBodyHtml = responseBodyHtml
        self.restrictToContacts = restrictToContacts
        self.restrictToDomain = restrictToDomain
        self.startTime = startTime
        self.endTime = endTime
    }

    enum CodingKeys: String, CodingKey {
        case enableAutoReply, responseSubject, responseBodyPlainText, responseBodyHtml
        case restrictToContacts, restrictToDomain, startTime, endTime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enableAutoReply = try container.decodeIfPresent(Bool.self, forKey: .enableAutoReply) ?? false
        responseSubject = try container.decodeIfPresent(String.self, forKey: .responseSubject)
        responseBodyPlainText = try container.decodeIfPresent(String.self, forKey: .responseBodyPlainText)
        responseBodyHtml = try container.decodeIfPresent(String.self, forKey: .responseBodyHtml)
        restrictToContacts = try container.decodeIfPresent(Bool.self, forKey: .restrictToContacts) ?? false
        restrictToDomain = try container.decodeIfPresent(Bool.self, forKey: .restrictToDomain) ?? false
        startTime = try Self.decodeTime(.startTime, in: container)
        endTime = try Self.decodeTime(.endTime, in: container)
    }

    /// Writes every field, unset ones as null, so an update never depends on
    /// how Gmail treats a missing field.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enableAutoReply, forKey: .enableAutoReply)
        try container.encode(responseSubject, forKey: .responseSubject)
        try container.encode(responseBodyPlainText, forKey: .responseBodyPlainText)
        try container.encode(responseBodyHtml, forKey: .responseBodyHtml)
        try container.encode(restrictToContacts, forKey: .restrictToContacts)
        try container.encode(restrictToDomain, forKey: .restrictToDomain)
        try container.encode(startTime.map(Self.milliseconds), forKey: .startTime)
        try container.encode(endTime.map(Self.milliseconds), forKey: .endTime)
    }

    /// Gmail's rules for an update: the start comes before the end, and an
    /// enabled reply has a subject or a body.
    public func validate() throws {
        if let startTime, let endTime, startTime >= endTime {
            throw GmailError.invalidRequest("Vacation start must come before its end")
        }
        let content = [responseSubject, responseBodyPlainText, responseBodyHtml]
        if enableAutoReply, content.allSatisfy({ $0.trimmedNonEmpty == nil }) {
            throw GmailError.invalidRequest("Vacation reply needs a subject or a body")
        }
    }

    private static func decodeTime(_ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>) throws -> Date? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let milliseconds = Int64(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not epoch milliseconds")
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
}

/// An address the account can send as, with its signature.
public struct SendAsIdentity: Decodable, Sendable, Equatable {
    public enum VerificationStatus: String, Decodable, Sendable {
        case accepted, pending, unspecified = "verificationStatusUnspecified"

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = VerificationStatus(rawValue: value) ?? .unspecified
        }
    }

    public let sendAsEmail: String
    public let displayName: String?
    public let replyToAddress: String?
    /// HTML that Gmail adds to new messages in its web client.
    public let signature: String?
    public let isPrimary: Bool
    public let isDefault: Bool
    public let treatAsAlias: Bool
    /// Gmail leaves it out for the primary address.
    public let verificationStatus: VerificationStatus

    /// Whether Gmail lets the account send as this address.
    public var canSend: Bool { isPrimary || verificationStatus == .accepted }

    enum CodingKeys: String, CodingKey {
        case sendAsEmail, displayName, replyToAddress, signature
        case isPrimary, isDefault, treatAsAlias, verificationStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sendAsEmail = try container.decode(String.self, forKey: .sendAsEmail)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        replyToAddress = try container.decodeIfPresent(String.self, forKey: .replyToAddress)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        treatAsAlias = try container.decodeIfPresent(Bool.self, forKey: .treatAsAlias) ?? false
        verificationStatus = try container.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus) ?? .unspecified
    }
}

struct FilterList: Decodable {
    let filter: [GmailFilter]?
}

struct SendAsList: Decodable {
    let sendAs: [SendAsIdentity]?
}
