import Foundation
import GRDB

/// A document's purpose, separate from its file format.
public enum AttachmentCategory: String, CaseIterable, Codable, Sendable {
    case uncategorized, invoice, receipt, contract, ticket, other

    public var title: String {
        switch self {
        case .uncategorized: "Uncategorized"
        case .invoice: "Invoice"
        case .receipt: "Receipt"
        case .contract: "Contract"
        case .ticket: "Ticket"
        case .other: "Other"
        }
    }
}

public enum AttachmentCategorySource: String, Codable, Sendable {
    case metadata, subject, content, manual
}

public enum AttachmentLibrarySort: String, CaseIterable, Codable, Sendable {
    case newest, oldest, filename, sender, largest, smallest

    public var title: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .filename: "Filename"
        case .sender: "Sender"
        case .largest: "Largest first"
        case .smallest: "Smallest first"
        }
    }
}

/// One occurrence of a file in an email. Identical files in other emails stay separate.
public struct AttachmentLibraryItem: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachmentLibrary"

    public var accountID: String
    public var messageID: String
    public var partID: String
    public var attachmentID: String?
    public var threadID: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var sender: String
    public var subject: String
    public var date: Date
    public var labelIDs: [String]
    public var category: AttachmentCategory
    public var categorySource: AttachmentCategorySource
    public var classificationVersion: Int
    public var contentClassificationVersion: Int
    public var classificationRetryAfter: Date?
    public var historyID: Int64
    public var generation: String?
    public private(set) var fileExtension: String
    var searchText: String
    var senderSearch: String

    /// Length prefixes keep identities distinct even when a provider ID contains a separator.
    public var id: String { [accountID, messageID, partID].map { "\($0.utf8.count):\($0)" }.joined() }

    public var attachment: AttachmentRecord {
        AttachmentRecord(accountID: accountID, messageID: messageID, partID: partID,
            attachmentID: attachmentID, filename: filename, mimeType: mimeType, size: size, isInline: false)
    }

    public init(attachment: AttachmentRecord, threadID: String, sender: String, subject: String,
                date: Date, labelIDs: [String] = [], category: AttachmentCategory? = nil,
                historyID: Int64 = 0, generation: String? = nil) {
        accountID = attachment.accountID
        messageID = attachment.messageID
        partID = attachment.partID
        attachmentID = attachment.attachmentID
        filename = attachment.filename
        mimeType = attachment.mimeType
        size = max(0, attachment.size)
        self.threadID = threadID
        self.sender = sender
        self.subject = subject
        self.date = date
        self.labelIDs = Array(Set(labelIDs)).sorted()
        if let category {
            self.category = category
            categorySource = .manual
        } else {
            let inferred = AttachmentClassification.metadataClassification(filename: attachment.filename,
                mimeType: attachment.mimeType, subject: subject)
            self.category = inferred.category
            categorySource = inferred.source
        }
        classificationVersion = AttachmentClassification.version
        contentClassificationVersion = 0
        classificationRetryAfter = nil
        self.historyID = historyID
        self.generation = generation
        fileExtension = Self.normalizedExtension(filename: attachment.filename, mimeType: attachment.mimeType)
        searchText = Self.searchNormalized([attachment.filename, sender, subject].joined(separator: "\n"))
        senderSearch = Self.searchNormalized(sender)
    }

    static func searchNormalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func normalizedExtension(filename: String, mimeType: String) -> String {
        let suffix = (filename as NSString).pathExtension.lowercased()
        if !suffix.isEmpty { return suffix }
        switch mimeType.lowercased().split(separator: ";").first {
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "application/zip": return "zip"
        default: return ""
        }
    }
}

public struct AttachmentLibraryLabel: Sendable, Hashable {
    public var accountID: String
    public var id: String

    public init(accountID: String, id: String) { self.accountID = accountID; self.id = id }
}

/// Search only covers metadata. It never reads or downloads document contents.
public struct AttachmentLibraryQuery: Sendable, Equatable {
    public var accountIDs: [String]
    public var search: String
    public var sender: String
    public var startDate: Date?
    /// Exclusive upper bound, so a date picker can pass the start of the following day.
    public var endDate: Date?
    public var fileExtension: String?
    public var category: AttachmentCategory?
    public var minimumSize: Int?
    public var maximumSize: Int?
    public var label: AttachmentLibraryLabel?
    public var sort: AttachmentLibrarySort
    public var limit: Int
    public var offset: Int

    public init(accountIDs: [String], search: String = "", sender: String = "", startDate: Date? = nil,
                endDate: Date? = nil, fileExtension: String? = nil, category: AttachmentCategory? = nil,
                minimumSize: Int? = nil, maximumSize: Int? = nil, label: AttachmentLibraryLabel? = nil,
                sort: AttachmentLibrarySort = .newest, limit: Int = 100, offset: Int = 0) {
        self.accountIDs = accountIDs
        self.search = search
        self.sender = sender
        self.startDate = startDate
        self.endDate = endDate
        self.fileExtension = fileExtension
        self.category = category
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.label = label
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }
}

public struct AttachmentLibraryPage: Sendable, Equatable {
    public var items: [AttachmentLibraryItem]
    public var totalCount: Int
    public var hasMore: Bool

    public init(items: [AttachmentLibraryItem], totalCount: Int, hasMore: Bool) {
        self.items = items; self.totalCount = totalCount; self.hasMore = hasMore
    }
}

/// A committed provider page and its coverage. State and that page's items are saved in one transaction.
public struct AttachmentIndexState: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachmentIndexState"

    public var accountID: String
    public var nextPageToken: String?
    public var historyID: Int64?
    public var historyPageToken: String?
    public var historyTargetID: Int64?
    /// History additions awaiting a bounded metadata fetch. Committed with the history page cursor.
    public var pendingMessageIDs: [String] = []
    public var indexedMessageCount: Int = 0
    public var isComplete: Bool = false
    public var updatedAt: Date?
    public var lastReconciledAt: Date?
    public var lastError: String?
    public var retryAfter: Date?
    public var failureCount: Int = 0
    public var generation: String?

    public init(accountID: String) { self.accountID = accountID }
}
