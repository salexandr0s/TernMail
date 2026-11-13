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
    private var generations: [Int64: UUID] = [:]
    private var isClosed = false
    /// The folder's deletions, each after the one before, off the main actor.
    private var folderRemoval: Task<Void, Never>?

    init(localDraftID: String) {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "Tern/Compose/\(localDraftID)", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// The copy of `attachment`, written from `data` the first time it's asked for.
    func url(for attachment: OutgoingAttachment, data: () async throws -> Data) async -> URL? {
        guard !isClosed, !Task.isCancelled, let id = attachment.id else { return nil }
        if let url = urls[id], FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        let generation = generations[id] ?? UUID()
        generations[id] = generation
        let directory = folder.appending(path: String(id), directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = directory.appending(path: Self.safeName(attachment.filename))
        do {
            let bytes = try await data()
            guard !isClosed, !Task.isCancelled, generations[id] == generation else { return nil }
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
            }.value
        } catch {
            discard(directory)
            return nil
        }
        // Removal, cancellation or window close may have happened during the write.
        guard !isClosed, !Task.isCancelled, generations[id] == generation else {
            discard(directory)
            return nil
        }
        urls[id] = url
        return url
    }

    func remove(_ attachment: OutgoingAttachment) {
        guard let id = attachment.id else { return }
        generations[id] = UUID()
        urls.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: folder.appending(path: String(id), directoryHint: .isDirectory))
    }

    func removeAll() {
        isClosed = true
        urls = [:]
        generations = [:]
        removeFolder()
    }

    /// Removes what a write left behind: its own directory, or the whole
    /// folder when the window closed meanwhile.
    private func discard(_ directory: URL) {
        if isClosed { removeFolder() } else { try? FileManager.default.removeItem(at: directory) }
    }

    /// Deletes the folder off the main actor, so a closing window never waits
    /// for the disk. The folder belongs to this window alone and takes no new
    /// file once closed. A write still under way asks again when it ends, and
    /// each deletion waits for the one before, so that file goes too.
    private func removeFolder() {
        let folder = folder
        let previous = folderRemoval
        folderRemoval = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Imported drafts can carry names a file can't have.
    private static func safeName(_ filename: String) -> String {
        let name = filename.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Attachment" : name
    }
}
