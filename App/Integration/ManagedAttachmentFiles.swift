import Foundation
import MailStore
import SyncEngine

enum ManagedAttachmentFiles {
    /// Reused downloads touch their timestamp. Keep recent copies for active previews.
    static let recentUseGrace: TimeInterval = 15 * 60

    static func totalBytes(in root: URL) -> Int64 {
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let entries = FileManager.default.enumerator(at: root,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { entries.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }

    static func folders(for attachments: [AttachmentRecord], in root: URL) -> [URL] {
        Array(Set(attachments.map {
            SyncEngine.attachmentCacheFolder(for: $0,
                in: root.appending(path: $0.accountID, directoryHint: .isDirectory))
        }))
    }

    static func canRemove(_ folder: URL, within root: URL, now: Date, protectedURLs: Set<URL> = []) -> Bool {
        let base = root.standardizedFileURL
        let candidate = folder.standardizedFileURL
        let relative = String(candidate.path.dropFirst(base.path.count + 1))
        let expected = base.resolvingSymlinksInPath().appending(path: relative).standardizedFileURL
        guard !protectedURLs.contains(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(expected.path + "/")
        }) else { return false }
        guard candidate.path.hasPrefix(base.path + "/"), candidate != base,
              let baseValues = try? base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              baseValues.isDirectory == true, baseValues.isSymbolicLink != true,
              candidate.resolvingSymlinksInPath().path == expected.path,
              let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let files = try? FileManager.default.contentsOfDirectory(at: candidate,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { return false }
        return files.allSatisfy { file in
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate else { return false }
            return modified <= now.addingTimeInterval(-recentUseGrace)
        }
    }

    @discardableResult
    static func remove(_ folder: URL, within root: URL, now: Date, protectedURLs: Set<URL> = []) throws -> Int64 {
        guard canRemove(folder, within: root, now: now, protectedURLs: protectedURLs) else { return 0 }
        let bytes = totalBytes(in: folder)
        try FileManager.default.removeItem(at: folder)
        return bytes
    }
}
