import Foundation

enum AttachmentFileExport {
    static func safeFilename(_ name: String) -> String {
        let value = name.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !value.isEmpty else { return "Attachment" }
        var bounded = ""
        for character in value {
            guard bounded.utf8.count + String(character).utf8.count <= 220 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "Attachment" : bounded
    }

    /// NSSavePanel has confirmed replacement. An atomic write preserves an
    /// existing destination if reading the source or writing the new file fails.
    static func save(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            try data.write(to: destination, options: .atomic)
        }.value
    }

    /// Folder exports never replace a user's file, including duplicate names
    /// from separate emails and another process creating a file during export.
    static func copyWithoutReplacing(_ source: URL, to directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let filename = safeFilename(source.lastPathComponent)
            let base = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            for suffix in 0..<10_000 {
                let candidate = suffix == 0 ? filename : base + " (\(suffix + 1))" + (ext.isEmpty ? "" : "." + ext)
                let target = directory.appending(path: candidate, directoryHint: .notDirectory)
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    return target
                } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
            }
            throw CocoaError(.fileWriteFileExists)
        }.value
    }
}
