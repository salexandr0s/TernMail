import Foundation

/// Serial file work has its own executor so large or slow files do not block
/// the account's sync actor. Copies are bounded even if the source grows.
actor OutgoingAttachmentIO {
    static let shared = OutgoingAttachmentIO()

    func size(of source: URL) throws -> Int {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if values.isDirectory == true { throw ComposeError.folder(source.lastPathComponent) }
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return size
    }

    func copy(_ source: URL, to destination: URL, maximumBytes: Int) throws -> Int {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard try size(of: source) <= maximumBytes else {
            throw ComposeError.fileTooLarge(source.lastPathComponent)
        }
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count = 0
        while let bytes = try input.read(upToCount: min(1_048_576, maximumBytes - count + 1)), !bytes.isEmpty {
            try Task.checkCancellation()
            guard bytes.count <= maximumBytes - count else {
                throw ComposeError.fileTooLarge(source.lastPathComponent)
            }
            try output.write(contentsOf: bytes)
            count += bytes.count
        }
        succeeded = true
        return count
    }

    func write(_ data: Data, to destination: URL, maximumBytes: Int, filename: String) throws -> Int {
        guard data.count <= maximumBytes else { throw ComposeError.fileTooLarge(filename) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return data.count
    }

    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
