import Foundation

/// Received files are disposable copies. Save/export destinations are never
/// passed here; the account's cache directory is deleted when it signs out.
enum AttachmentFileCache {
    static let maximumBytes = 512 * 1_024 * 1_024
    static let maximumFiles = 1_000
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    static func isReusable(_ url: URL, expectedSize: Int, now: Date) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let date = values.contentModificationDate, date > now.addingTimeInterval(-lifetime) else { return false }
        return expectedSize <= 0 || values.fileSize == expectedSize
    }

    static func prune(_ directory: URL, keeping activeURL: URL, now: Date,
                      maximumBytes: Int = maximumBytes, lifetime: TimeInterval = lifetime) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        var count = files.count
        for file in files.sorted(by: { $0.date < $1.date }) where file.url != activeURL {
            guard total > maximumBytes || count > maximumFiles || file.date < now.addingTimeInterval(-lifetime) else { continue }
            do { try FileManager.default.removeItem(at: file.url) } catch { continue }
            total -= file.size
            count -= 1
            let folder = file.url.deletingLastPathComponent()
            if folder != directory, (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
