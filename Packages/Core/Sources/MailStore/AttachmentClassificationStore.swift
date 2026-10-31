import Foundation
import GRDB

public enum AttachmentClassification {
    public static let version = 2
    public static let maximumContentBytes = 10 * 1_024 * 1_024

    static func metadataClassification(filename: String, mimeType: String, subject: String)
        -> (category: AttachmentCategory, source: AttachmentCategorySource) {
        let category = AttachmentCategoryClassifier.classify(filename: filename, mimeType: mimeType, subject: subject)
        guard category != .uncategorized else { return (category, .metadata) }
        let withoutSubject = AttachmentCategoryClassifier.classify(filename: filename, mimeType: mimeType, subject: "")
        return (category, withoutSubject == category ? .metadata : .subject)
    }
}

extension AttachmentLibraryItem {
    /// Gmail can change its download hint without changing the file. Label
    /// updates also advance historyID, so neither invalidates extracted text.
    func matchesClassificationInput(_ other: AttachmentLibraryItem) -> Bool {
        accountID == other.accountID && messageID == other.messageID && partID == other.partID
            && filename == other.filename && mimeType == other.mimeType && size == other.size
            && subject == other.subject
    }
}

extension MailCache {
    public func pendingAttachmentClassifications(accountID: String, limit: Int = 3,
                                                 now: Date = Date()) async throws -> [AttachmentLibraryItem] {
        try await read { try $0.pendingAttachmentClassifications(accountID: accountID, limit: limit, now: now) }
    }

    public func applyAttachmentClassification(_ category: AttachmentCategory, for item: AttachmentLibraryItem) async throws {
        try await write { try $0.applyAttachmentClassification(category, for: item) }
    }

    public func deferAttachmentClassification(for item: AttachmentLibraryItem, until retryAfter: Date) async throws {
        try await write { try $0.deferAttachmentClassification(for: item, until: retryAfter) }
    }
}

extension CacheTransaction {
    public func pendingAttachmentClassifications(accountID: String, limit: Int = 3,
                                                 now: Date = Date()) throws -> [AttachmentLibraryItem] {
        guard limit > 0 else { return [] }
        return try AttachmentLibraryItem.fetchAll(db, sql: """
            SELECT * FROM attachmentLibrary
            WHERE accountID = ? AND categorySource != 'manual'
              AND (category = 'uncategorized' OR categorySource = 'subject')
              AND contentClassificationVersion < ? AND size <= ?
              AND (classificationRetryAfter IS NULL OR classificationRetryAfter <= ?)
              AND (fileExtension IN ('pdf','png','jpg','jpeg','tif','tiff','heic','heif','webp','bmp','gif','txt','csv','md')
                   OR lower(trim(substr(mimeType, 1, instr(mimeType || ';', ';') - 1))) IN
                      ('application/pdf','image/png','image/jpeg','image/tiff','image/heic','image/heif',
                       'image/webp','image/bmp','image/gif','text/plain','text/csv','text/markdown'))
            ORDER BY date DESC, messageID, partID LIMIT ?
            """, arguments: [accountID, AttachmentClassification.version, AttachmentClassification.maximumContentBytes,
                now, min(limit, 25)])
    }

    /// A completed extraction, including one with no useful text, is attempted
    /// only once per classifier version. User edits always take precedence.
    public func applyAttachmentClassification(_ category: AttachmentCategory, for item: AttachmentLibraryItem) throws {
        guard var current = try classificationTarget(for: item) else { return }
        current.category = category
        current.categorySource = .content
        current.classificationVersion = AttachmentClassification.version
        current.contentClassificationVersion = AttachmentClassification.version
        current.classificationRetryAfter = nil
        try current.update(db)
    }

    /// Retry a temporary failure later while allowing other files to progress.
    public func deferAttachmentClassification(for item: AttachmentLibraryItem, until retryAfter: Date) throws {
        guard var current = try classificationTarget(for: item) else { return }
        current.classificationRetryAfter = retryAfter
        try current.update(db)
    }

    private func classificationTarget(for item: AttachmentLibraryItem) throws -> AttachmentLibraryItem? {
        guard let current = try libraryAttachment(accountID: item.accountID, messageID: item.messageID, partID: item.partID),
              current.categorySource != .manual, current.matchesClassificationInput(item),
              current.contentClassificationVersion <= item.contentClassificationVersion else { return nil }
        return current
    }
}
