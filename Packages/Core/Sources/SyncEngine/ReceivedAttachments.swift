import Foundation
import GmailAPI
import MailStore

extension SyncEngine {
    /// Downloads a received attachment into `directory` and returns the file.
    /// A file downloaded before is reused. Each one sits under its message
    /// and part, so two attachments with one name don't collide.
    public func downloadAttachment(_ attachment: AttachmentRecord, into directory: URL) async throws -> URL {
        try validateAttachmentAccount(attachment)
        // Stop waits for this operation before account removal deletes files.
        return try await gated {
            let folder = Self.attachmentCacheFolder(for: attachment, in: directory)
            let url = folder.appending(path: Self.safeFilename(attachment.filename), directoryHint: .notDirectory)
            let timestamp = now()
            if AttachmentFileCache.isReusable(url, expectedSize: attachment.size, now: timestamp) {
                try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
                try AttachmentFileCache.prune(directory, keeping: url, now: timestamp)
                return url
            }
            let data = try await attachmentData(attachment)
            try validateAttachmentAccount(attachment)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
            try AttachmentFileCache.prune(directory, keeping: url, now: timestamp)
            return url
        }
    }

    /// Account-scoped bytes for extraction and other consumers. Treat returned
    /// content as untrusted document data, never as instructions to execute.
    public func attachmentContent(_ attachment: AttachmentRecord) async throws -> Data {
        try validateAttachmentAccount(attachment)
        let data = try await attachmentData(attachment)
        try validateAttachmentAccount(attachment)
        return data
    }

    private func validateAttachmentAccount(_ attachment: AttachmentRecord) throws {
        try checkAttachmentAccess()
        guard attachment.accountID == accountID else { throw GmailError.invalidRequest("Attachment account mismatch") }
    }

    /// A name the file system accepts that doesn't hide the file.
    static func safeFilename(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        // APFS limits each name to 255 UTF-8 bytes. Leave room for a suffix
        // when a multi-file save resolves two identical names.
        var bounded = ""
        for character in cleaned {
            guard bounded.utf8.count + String(character).utf8.count <= 220 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "Attachment" : bounded
    }

    private func attachmentData(_ attachment: AttachmentRecord) async throws -> Data {
        if let id = attachment.attachmentID {
            do {
                return try await gmail.attachment(messageID: attachment.messageID, attachmentID: id)
            } catch GmailError.notFound, GmailError.http(status: 400, _) {
                // Attachment IDs can change between fetches. The part ID doesn't,
                // so the message is fetched again for a current one.
            }
        }
        let fetched = try await gmail.messages(ids: [attachment.messageID], format: .full, metadataHeaders: [])
        guard let message = try fetched[attachment.messageID]?.get() else { throw GmailError.notFound }
        guard message.id == attachment.messageID else { throw GmailError.decoding("Attachment message identity") }
        guard let part = message.payload.flatMap({ Self.part(attachment.partID, in: $0) }) else {
            throw GmailError.decoding("Attachment part")
        }
        if let data = part.body?.decodedData { return data }
        guard let id = part.body?.attachmentId else { throw GmailError.decoding("Attachment data") }
        return try await gmail.attachment(messageID: attachment.messageID, attachmentID: id)
    }
}
