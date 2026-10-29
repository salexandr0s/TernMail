import Foundation
import GmailAPI
import MailStore

extension SyncEngine {
    /// Downloads a received attachment into `directory` and returns the file.
    /// A file downloaded before is reused. Each one sits under its message
    /// and part, so two attachments with one name don't collide.
    public func downloadAttachment(_ attachment: AttachmentRecord, into directory: URL) async throws -> URL {
        let folder = directory
            .appending(path: attachment.messageID, directoryHint: .isDirectory)
            .appending(path: attachment.partID, directoryHint: .isDirectory)
        let url = folder.appending(path: Self.safeFilename(attachment.filename), directoryHint: .notDirectory)
        // Writes are atomic, so a file that exists is complete.
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await attachmentData(attachment)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A name the file system accepts that doesn't hide the file.
    static func safeFilename(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Attachment" : cleaned
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
        guard let part = message.payload.flatMap({ Self.part(attachment.partID, in: $0) }) else {
            throw GmailError.decoding("Attachment part")
        }
        if let data = part.body?.decodedData { return data }
        guard let id = part.body?.attachmentId else { throw GmailError.decoding("Attachment data") }
        return try await gmail.attachment(messageID: attachment.messageID, attachmentID: id)
    }
}
