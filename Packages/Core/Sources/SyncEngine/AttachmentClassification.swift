import Foundation
import GmailAPI
import MailStore

extension SyncEngine {
    /// Classifies a small batch of unresolved documents using local text/OCR.
    /// Metadata indexing remains independent, so an unreadable file cannot
    /// stop mail discovery or delay its durable checkpoint.
    @discardableResult
    public func classifyAttachments(limit: Int = 3) async throws -> Int {
        try checkAttachmentAccess()
        if let attachmentClassificationPass { return try await attachmentClassificationPass.value }
        let task = Task {
            defer { attachmentClassificationPass = nil }
            return try await classifyAttachmentBatch(limit: max(1, min(limit, 3)))
        }
        attachmentClassificationPass = task
        return try await task.value
    }

    private func classifyAttachmentBatch(limit: Int) async throws -> Int {
        let pending = try await cache.pendingAttachmentClassifications(accountID: accountID, limit: limit, now: now())
        for item in pending {
            try checkAttachmentAccess()
            let data: Data
            do {
                data = try await attachmentContent(item.attachment)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try checkAttachmentAccess()
                switch error as? GmailError {
                case .notFound?, .decoding?:
                    // attachmentContent has already refreshed a stale download
                    // ID. A missing part or malformed payload cannot be read.
                    try await write { try $0.applyAttachmentClassification(item.category, for: item) }
                    continue
                default: break
                }
                // A failed download is not evidence about the document. Keep
                // it eligible for a later run while letting other files pass.
                let retry = now().addingTimeInterval(300)
                try await write { try $0.deferAttachmentClassification(for: item, until: retry) }
                if let error = error as? GmailError,
                   error == .unauthorized || error == .rateLimited || error.isMissingScope { break }
                continue
            }
            try checkAttachmentAccess()
            let extraction = Task.detached(priority: .utility) {
                try AttachmentClassificationText.extract(data, mimeType: item.mimeType, filename: item.filename)
            }
            let text = try await withTaskCancellationHandler {
                try await extraction.value
            } onCancel: {
                extraction.cancel()
            }
            try checkAttachmentAccess()
            let category = AttachmentCategoryClassifier.classify(filename: item.filename,
                mimeType: item.mimeType, subject: item.subject, text: text)
            try await write { try $0.applyAttachmentClassification(category, for: item) }
        }
        return pending.count
    }
}
