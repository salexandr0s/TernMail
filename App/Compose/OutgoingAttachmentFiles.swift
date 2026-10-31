import Foundation
import MailStore

/// Copies of a draft's attachments under their own names, for Quick Look,
/// dragging out and Finder. The draft stores each file under a generated name,
/// which those would otherwise show. The copies live in the temporary folder
/// and go when the window closes.
@MainActor
final class OutgoingAttachmentFiles {
    private let folder: URL
    private var urls: [Int64: URL] = [:]
    private var isClosed = false

    init(localDraftID: String) {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "Tern/Compose/\(localDraftID)", directoryHint: .isDirectory)
    }

    /// The copy of `attachment`, written from `data` the first time it's asked for.
    func url(for attachment: OutgoingAttachment, data: () async throws -> Data) async -> URL? {
        guard !isClosed, let id = attachment.id else { return nil }
        if let url = urls[id], FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        let directory = folder.appending(path: String(id), directoryHint: .isDirectory)
        let url = directory.appending(path: Self.safeName(attachment.filename))
        do {
            let bytes = try await data()
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
            }.value
        } catch {
            return nil
        }
        // The window closed while the file was copied.
        guard !isClosed else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        urls[id] = url
        return url
    }

    func remove(_ attachment: OutgoingAttachment) {
        guard let id = attachment.id, let url = urls.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func removeAll() {
        isClosed = true
        urls = [:]
        try? FileManager.default.removeItem(at: folder)
    }

    /// Imported drafts can carry names a file can't have.
    private static func safeName(_ filename: String) -> String {
        let name = filename.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Attachment" : name
    }
}
