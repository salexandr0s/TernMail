import Foundation

// Response shapes from the Gmail REST API (v1). Fields Gmail may omit are optional.
// History IDs are unsigned 64-bit integers that Gmail sends as strings.

public struct GmailProfile: Decodable, Sendable, Equatable {
    public let emailAddress: String
    public let messagesTotal: Int?
    public let threadsTotal: Int?
    public let historyId: String
}

public struct GmailLabel: Decodable, Sendable, Equatable {
    public struct Color: Decodable, Sendable, Equatable {
        public let textColor: String?
        public let backgroundColor: String?
    }

    public let id: String
    public let name: String
    /// "system" or "user".
    public let type: String?
    public let labelListVisibility: String?
    public let messageListVisibility: String?
    /// Counts are only present on `labels.get`, not on `labels.list`.
    public let messagesTotal: Int?
    public let messagesUnread: Int?
    public let threadsTotal: Int?
    public let threadsUnread: Int?
    public let color: Color?

    public var isSystem: Bool { type == "system" }
}

struct LabelList: Decodable {
    let labels: [GmailLabel]?
}

public struct MessageRef: Decodable, Sendable, Hashable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
}

public struct MessageListPage: Decodable, Sendable {
    public let messages: [MessageRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?
}

public enum MessageFormat: String, Sendable {
    case minimal, metadata, full
}

public struct GmailMessage: Decodable, Sendable, Equatable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let historyId: String?
    /// Milliseconds since 1970, as a string.
    public let internalDate: String?
    public let sizeEstimate: Int?
    public let payload: MessagePart?

    public var date: Date? {
        guard let internalDate, let milliseconds = Int64(internalDate) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// Seconds east of UTC in the `Date` header: the zone of the clock the
    /// message was sent from. Nil without the header, for "-0000", which
    /// RFC 5322 keeps for an unknown zone, and for zone names it doesn't list.
    public var dateHeaderOffset: Int? {
        header("Date").flatMap(Self.utcOffset(inDateHeader:))
    }

    public func header(_ name: String) -> String? {
        payload?.header(name)
    }

    /// The zone follows the time of day, as in "Tue, 1 Jul 2031 10:52:37 +0200 (CEST)".
    private static func utcOffset(inDateHeader value: String) -> Int? {
        let tokens = value.split(whereSeparator: \.isWhitespace)
        guard let time = tokens.firstIndex(where: { $0.contains(":") }), time + 1 < tokens.count else { return nil }
        let zone = tokens[time + 1]
        guard let sign = zone.first, sign == "+" || sign == "-" else {
            return namedZones[zone.uppercased()].map { $0 * 3_600 }
        }
        let digits = zone.dropFirst()
        guard digits.count == 4, digits.allSatisfy({ ("0"..."9").contains($0) }),
              let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 18, minutes < 60, zone != "-0000" else { return nil }
        let seconds = (hours * 60 + minutes) * 60
        return sign == "-" ? -seconds : seconds
    }

    /// RFC 5322's obsolete zone names, plus UTC, in hours. The RFC reads the
    /// military letters as an unknown zone, so they are left out.
    private static let namedZones = [
        "UT": 0, "UTC": 0, "GMT": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
    ]
}

public struct MessagePart: Decodable, Sendable, Equatable {
    public struct Header: Decodable, Sendable, Equatable {
        public let name: String
        public let value: String
    }

    public struct Body: Decodable, Sendable, Equatable {
        public let attachmentId: String?
        public let size: Int?
        /// Base64url-encoded content, present for inline parts.
        public let data: String?

        public var decodedData: Data? {
            data.flatMap(Data.init(base64URLEncoded:))
        }
    }

    public let partId: String?
    public let mimeType: String?
    public let filename: String?
    public let headers: [Header]?
    public let body: Body?
    public let parts: [MessagePart]?

    public func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct GmailThread: Decodable, Sendable, Equatable {
    public let id: String
    public let historyId: String?
    public let snippet: String?
    public let messages: [GmailMessage]?
}

public struct GmailDraft: Decodable, Sendable, Equatable {
    public let id: String
    /// On `drafts.list` and after a save, only the message's ID, thread ID and labels.
    public let message: GmailMessage?
}

public struct DraftListPage: Decodable, Sendable {
    public let drafts: [GmailDraft]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?
}

public struct HistoryPage: Decodable, Sendable {
    public let history: [HistoryRecord]?
    public let nextPageToken: String?
    /// The mailbox's current history ID. Store it after the last page.
    public let historyId: String
}

public struct HistoryRecord: Decodable, Sendable, Equatable {
    public struct MessageChange: Decodable, Sendable, Equatable {
        public let message: MessageRef
    }

    public struct LabelChange: Decodable, Sendable, Equatable {
        public let message: MessageRef
        public let labelIds: [String]
    }

    public let id: String
    public let messagesAdded: [MessageChange]?
    public let messagesDeleted: [MessageChange]?
    public let labelsAdded: [LabelChange]?
    public let labelsRemoved: [LabelChange]?
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
