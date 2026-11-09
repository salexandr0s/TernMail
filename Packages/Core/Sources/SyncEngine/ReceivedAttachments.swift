import Foundation
import GmailAPI
import MailStore
import UniformTypeIdentifiers

extension SyncEngine {
    /// Downloads a received attachment into `directory` and returns the file.
    /// A file downloaded before is reused. Each one sits under its message
    /// and part, so two attachments with one name don't collide.
    /// Active previews are read just before pruning so navigation during a
    /// download protects the file currently on screen.
    public func downloadAttachment(_ attachment: AttachmentRecord, into directory: URL,
        protectedURLs: (@Sendable () async -> Set<URL>)? = nil) async throws -> URL {
        try validateAttachmentAccount(attachment)
        // Stop waits for this operation before account removal deletes files.
        return try await gated {
            let folder = Self.attachmentCacheFolder(for: attachment, in: directory)
            let url = folder.appending(path: Self.safeFilename(attachment.filename), directoryHint: .notDirectory)
            let timestamp = now()
            if AttachmentFileCache.isReusable(url, expectedSize: attachment.size, now: timestamp) {
                try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
                let protection = await protectedURLs?() ?? []
                try validateAttachmentAccount(attachment)
                try AttachmentFileCache.prune(directory, keeping: url, now: timestamp, protectedURLs: protection)
                return url
            }
            let data = try await attachmentData(attachment)
            try validateAttachmentAccount(attachment)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
            let protection = await protectedURLs?() ?? []
            try validateAttachmentAccount(attachment)
            try AttachmentFileCache.prune(directory, keeping: url, now: timestamp, protectedURLs: protection)
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

    /// The name a received attachment has on disk, which is also the name to
    /// show for it. Bidi and other invisible format controls are removed, so
    /// the name reads in the order its characters are stored and visibly ends
    /// with the extension that decides how the file opens. Zero-width joiners
    /// stay, because Persian words and emoji sequences need them. Leading dots
    /// are removed so the file isn't hidden.
    public static func safeFilename(_ name: String) -> String {
        var visible = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control: continue
            case .format where !filenameJoiners.contains(scalar): continue
            // A line break could move the real extension to a line a one-line label hides.
            case .lineSeparator, .paragraphSeparator: visible.append(" ")
            // Scalar by scalar, because string replacement skips a "/" that a combining mark follows.
            default: visible.append(scalar == "/" || scalar == ":" ? "-" : scalar)
            }
        }
        let cleaned = String(visible).trimmingCharacters(in: filenameEdges)
        guard cleaned.utf8.count > maxFilenameBytes else { return cleaned.isEmpty ? fallbackFilename : cleaned }
        // A long name loses the end of its stem, never its extension, so a
        // shortened "report.command.pdf" can't become a Terminal script.
        let ext = (cleaned as NSString).pathExtension
        let stemBytes = maxFilenameBytes - ext.utf8.count - 1
        if !ext.isEmpty, stemBytes >= fallbackFilename.utf8.count {
            let stem = leadingCharacters(of: (cleaned as NSString).deletingPathExtension, fitting: stemBytes)
                .trimmingCharacters(in: filenameEdges)
            return (stem.isEmpty ? fallbackFilename : stem) + "." + ext
        }
        // Without an extension to keep, the cut could end just after a dot
        // inside the name and give the file a type, so that name loses its dots.
        let shortened = leadingCharacters(of: cleaned, fitting: maxFilenameBytes).trimmingCharacters(in: filenameEdges)
        let typeless = (shortened as NSString).pathExtension.isEmpty
            ? shortened : shortened.replacingOccurrences(of: ".", with: "-")
        return typeless.isEmpty ? fallbackFilename : typeless
    }

    /// Whether opening a file with this name can run code: apps, installers,
    /// executables, scripts (Terminal runs `.command` and `.tool` files),
    /// Terminal settings files, which can run a command when they open, and
    /// location files, which can open an app. Like Launch Services for the
    /// files Tern saves, this decides the type from the extension.
    public static func runsCodeWhenOpened(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return codeRunningTypes.contains { type.conforms(to: $0) }
    }

    /// `.command` and `.tool` files are scripts but not executables, and
    /// installer packages conform only to archive, so each kind is listed.
    private static let codeRunningTypes: [UTType] = [.executable, .script, .application, .internetLocation, .internetShortcut]
        + ["com.apple.installer-package-archive", "com.apple.installer-meta-package", "com.apple.terminal.settings",
           "com.apple.terminal.session", "com.sun.java-web-start"].compactMap { UTType($0) }

    /// APFS allows 255 UTF-8 bytes per name. The rest leaves room for the
    /// " (2)" a folder export adds when two files share a name.
    private static let maxFilenameBytes = 220
    private static let fallbackFilename = "Attachment"
    private static let filenameJoiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]
    private static let filenameEdges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".\u{200C}\u{200D}"))

    /// Whole characters from the start of `text`, as many as fit in `bytes` of UTF-8.
    private static func leadingCharacters(of text: String, fitting bytes: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            used += character.utf8.count
            guard used <= bytes else { break }
            result.append(character)
        }
        return result
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
