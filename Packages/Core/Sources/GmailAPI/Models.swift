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

    public func header(_ name: String) -> String? {
        payload?.header(name)
    }
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
