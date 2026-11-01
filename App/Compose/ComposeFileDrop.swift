import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ComposeFileDropError: Error, LocalizedError, Equatable, Sendable {
    case tooLarge

    var errorDescription: String? { "This file is larger than the 35 MB import limit." }
}

/// One accepted file drop. Consumers retain it while reading or offering Retry.
/// Its staging copy survives provider callbacks and is removed with the reference.
@MainActor
final class ComposeDroppedFile: Identifiable, Sendable {
    nonisolated static let maximumBytes = 35_000_000
    nonisolated let id = UUID()
    nonisolated let filename: String
    private let storage = ComposeDropStorage()
    private let materialize: @MainActor (ComposeDropStorage) async throws -> URL
    private var loading: (id: UUID, task: Task<URL, any Error>)?

    init(url: URL) {
        filename = Self.safeName(url.lastPathComponent)
        materialize = { storage in
            try await Task.detached { try storage.copy(url, named: nil) }.value
        }
    }

    /// A durable source, also useful for importers that finish their own copy.
    init(filename: String, load: @escaping @MainActor () async throws -> URL) {
        let name = Self.safeName(filename)
        self.filename = name
        materialize = { storage in
            let url = try await load()
            return try await Task.detached { try storage.copy(url, named: name) }.value
        }
    }

    private init(filename: String, materialize: @escaping @MainActor (ComposeDropStorage) async throws -> URL) {
        self.filename = Self.safeName(filename)
        self.materialize = materialize
    }

    func fileURL() async throws -> URL {
        try Task.checkCancellation()
        let request: (id: UUID, task: Task<URL, any Error>)
        if let loading { request = loading }
        else {
            request = (UUID(), Task { [materialize, storage] in try await materialize(storage) })
            loading = request
        }
        let url: URL
        do { url = try await request.task.value }
        catch {
            // Cancellation of a consumer must not cancel a copy another consumer
            // is awaiting. A failed materialization can be retried on this source.
            if loading?.id == request.id { loading = nil }
            throw error
        }
        try Task.checkCancellation()
        return url
    }

    static let pasteboardTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func accepts(_ pasteboard: NSPasteboard, allowFilePromises: Bool = true) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if allowFilePromises, pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        return imageOnlyType(on: pasteboard) != nil
    }

    /// Native promises can only be accepted during AppKit drag callbacks.
    /// Paste callers disable them; drag validation should use accepts(_:).
    static func from(pasteboard: NSPasteboard, allowFilePromises: Bool = true) -> [ComposeDroppedFile] {
        var files: [ComposeDroppedFile] = []
        var receivers: [NSFilePromiseReceiver] = []
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        for item in pasteboard.pasteboardItems ?? [] {
            if let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL {
                files.append(ComposeDroppedFile(url: url))
            } else if allowFilePromises, let type = promiseTypes.first(where: { item.types.contains($0) }),
                      let property = item.propertyList(forType: type),
                      let receiver = NSFilePromiseReceiver(pasteboardPropertyList: property, ofType: type) {
                receivers.append(receiver)
            }
        }
        if !receivers.isEmpty { files += ComposeFilePromises.receive(receivers) }
        if files.isEmpty, let type = imageOnlyType(on: pasteboard), let data = pasteboard.data(forType: type) {
            let filename = type == .png ? "Dropped image.png" : "Dropped image.tiff"
            files.append(ComposeDroppedFile(filename: filename) { storage in
                try await Task.detached { try storage.write(data, named: filename) }.value
            })
        }
        return files
    }

    static func accepts(providers: [NSItemProvider]) -> Bool {
        providers.contains { representation(for: $0) != nil }
    }

    static func from(providers: [NSItemProvider]) -> [ComposeDroppedFile] {
        providers.compactMap { provider in
            guard let type = representation(for: provider) else { return nil }
            let extensionName = UTType(type)?.preferredFilenameExtension
            let name = provider.suggestedName.map { suggested in
                let safe = Self.safeName(suggested)
                return (safe as NSString).pathExtension.isEmpty && extensionName != nil
                    ? safe + "." + (extensionName ?? "") : safe
            }
            let fallback = extensionName.map { "Dropped file." + $0 } ?? "Dropped file"
            return ComposeDroppedFile(filename: name ?? fallback) { storage in
                try await withCheckedThrowingContinuation { continuation in
                    if type == UTType.fileURL.identifier {
                        provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                            do {
                                if let error { throw error }
                                let url: URL?
                                switch item {
                                case let value as URL: url = value
                                case let value as Data: url = URL(dataRepresentation: value, relativeTo: nil)
                                case let value as String: url = URL(string: value)
                                default: url = nil
                                }
                                guard let url else { throw CocoaError(.fileReadUnknown) }
                                continuation.resume(returning: try storage.copy(url, named: nil))
                            } catch { continuation.resume(throwing: error) }
                        }
                    } else {
                        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                            do {
                                if let error { throw error }
                                guard let url else { throw CocoaError(.fileReadUnknown) }
                                // Provider temporary URLs expire when this callback returns.
                                let filename = name.map {
                                    ($0 as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? $0 + "." + url.pathExtension : $0
                                }
                                continuation.resume(returning: try storage.copy(url, named: filename))
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                }
            }
        }
    }

    private static func representation(for provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return UTType.fileURL.identifier }
        // Text, rich text and web links must remain text drags, even when the
        // provider could turn their bytes into a temporary file.
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return nil }
        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
        }
    }

    private static func imageOnlyType(on pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        guard pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              pasteboard.availableType(from: [.URL, .html, .rtf]) == nil else { return nil }
        return pasteboard.availableType(from: [.png, .tiff])
    }

    nonisolated fileprivate static func safeName(_ name: String) -> String {
        let component = (name as NSString).lastPathComponent.replacingOccurrences(of: "\0", with: "")
        return component.isEmpty || component == "." || component == ".." ? "Dropped file" : component
    }
}

/// Immutable ownership keeps callback copies alive without cross-actor mutation.
private final class ComposeDropStorage: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tern-Drop-" + UUID().uuidString, isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: directory) }

    func copy(_ source: URL, named preferredName: String?) throws -> URL {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var freshSource = source
        freshSource.removeAllCachedResourceValues()
        let values = try freshSource.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
        guard size <= ComposeDroppedFile.maximumBytes else { throw ComposeFileDropError.tooLarge }
        let target = try destination(named: preferredName ?? source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            // The source could have grown since its preflight check.
            guard let copiedSize = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw CocoaError(.fileReadUnknown) }
            guard copiedSize <= ComposeDroppedFile.maximumBytes else { throw ComposeFileDropError.tooLarge }
            return target
        }
        catch { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()); throw error }
    }

    func write(_ data: Data, named filename: String) throws -> URL {
        guard data.count <= ComposeDroppedFile.maximumBytes else { throw ComposeFileDropError.tooLarge }
        let target = try destination(named: filename)
        do { try data.write(to: target, options: .atomic); return target }
        catch { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()); throw error }
    }

    private func destination(named filename: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(ComposeDroppedFile.safeName(filename))
    }
}

/// All receivers in a native drag share one destination, as AppKit requires.
@MainActor
private final class ComposeFilePromises {
    private struct Key: Hashable { let receiver: Int; let index: Int }
    private let storage = ComposeDropStorage()
    private var names: [Int: [String]] = [:]
    private var outcomes: [Key: Result<URL, any Error>] = [:]
    private var waiting: [Key: [CheckedContinuation<URL, any Error>]] = [:]

    static func receive(_ receivers: [NSFilePromiseReceiver]) -> [ComposeDroppedFile] {
        let batch = ComposeFilePromises()
        let destination = batch.storage.directory.appendingPathComponent("Incoming", isDirectory: true)
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { return receivers.map { _ in ComposeDroppedFile(filename: "Dropped file", load: { throw error }) } }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        var files: [ComposeDroppedFile] = []
        for (receiverID, receiver) in receivers.enumerated() {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { [weak batch, storage = batch.storage] url, error in
                let result: Result<URL, any Error>
                do {
                    if let error { throw error }
                    // The reader is coordinated by AppKit. Copy before leaving it.
                    result = .success(try storage.copy(url, named: nil))
                } catch { result = .failure(error) }
                Task { @MainActor [weak batch] in batch?.finish(receiver: receiverID, filename: url.lastPathComponent, result: result) }
            }
            let names = receiver.fileNames.isEmpty
                ? receiver.fileTypes.map { UTType($0)?.preferredFilenameExtension.map { "Dropped file." + $0 } ?? "Dropped file" }
                : receiver.fileNames
            batch.names[receiverID] = names.isEmpty ? ["Dropped file"] : names
            for (index, name) in (batch.names[receiverID] ?? []).enumerated() {
                let key = Key(receiver: receiverID, index: index)
                files.append(ComposeDroppedFile(filename: name, load: { try await batch.fileURL(for: key) }))
            }
        }
        return files
    }

    private func fileURL(for key: Key) async throws -> URL {
        if let result = outcomes[key] { return try result.get() }
        return try await withCheckedThrowingContinuation { waiting[key, default: []].append($0) }
    }

    private func finish(receiver: Int, filename: String, result: Result<URL, any Error>) {
        let candidates = (names[receiver] ?? []).indices.map { Key(receiver: receiver, index: $0) }
        guard let key = candidates.first(where: { names[receiver]?[$0.index] == filename && outcomes[$0] == nil })
            ?? candidates.first(where: { outcomes[$0] == nil }) else { return }
        outcomes[key] = result
        for continuation in waiting.removeValue(forKey: key) ?? [] { continuation.resume(with: result) }
    }
}

extension View {
    func composeFileDrop(isEnabled: Bool, isTargeted: Binding<Bool>,
                         onDrop: @escaping @MainActor ([ComposeDroppedFile]) -> Void) -> some View {
        self.onDrop(of: [.fileURL, .data], delegate: ComposeFileDropDelegate(isEnabled: isEnabled, isTargeted: isTargeted, onDrop: onDrop))
    }
}

@MainActor
private struct ComposeFileDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: @MainActor ([ComposeDroppedFile]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        return ComposeDroppedFile.accepts(providers: info.itemProviders(for: [.fileURL, .data]))
    }
    func dropEntered(info: DropInfo) { isTargeted = isEnabled }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: isEnabled ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL, .data])
        guard ComposeDroppedFile.accepts(providers: providers) else { return false }
        if isEnabled { onDrop(ComposeDroppedFile.from(providers: providers)) }
        return true
    }
}
