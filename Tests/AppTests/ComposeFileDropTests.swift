import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Tern

@Suite @MainActor struct ComposeFileDropTests {
    @Test func stagedFileSurvivesItsSourceAndIsRemovedWithItsOwner() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Dinner notes.txt")
        let data = Data("Friday at seven".utf8)
        try data.write(to: original)
        var source: ComposeDroppedFile? = ComposeDroppedFile(url: original)
        let staged = try await #require(source).fileURL()
        #expect(staged != original)
        #expect(staged.lastPathComponent == original.lastPathComponent)
        try FileManager.default.removeItem(at: original)
        #expect(try Data(contentsOf: staged) == data)
        #expect(try await #require(source).fileURL() == staged)
        source = nil
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test(arguments: [UTType.data, UTType.png])
    func fileProviderCopyOutlivesTheTemporaryCallbackURL(type: UTType) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent("provider-copy")
        let data = Data("Meeting details".utf8)
        try data.write(to: temporary)
        let provider = NSItemProvider()
        provider.suggestedName = type == .data ? "Meeting.txt" : "Meeting"
        let expectedName = type == .data ? "Meeting.txt" : "Meeting.png"
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(temporary, false, nil)
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        let source = try #require(ComposeDroppedFile.from(providers: [provider]).first)
        #expect(source.filename == expectedName)
        let staged = try await source.fileURL()
        await Task.yield()
        #expect(staged.lastPathComponent == expectedName)
        #expect(try Data(contentsOf: staged) == data)
        #expect(try await source.fileURL() == staged)
    }

    @Test func fileURLWinsOverOtherRepresentationsOfTheSameItem() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Only once.txt")
        try Data("One file".utf8).write(to: original)
        let provider = NSItemProvider(object: original as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let sources = ComposeDroppedFile.from(providers: [provider])
        #expect(sources.count == 1)
        let staged = try await #require(sources.first).fileURL()
        #expect(staged.lastPathComponent == "Only once.txt")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "One file")
    }

    @Test func plainTextAndWebLinksDoNotBecomeFiles() {
        let text = NSItemProvider(object: "Ordinary prompt text" as NSString)
        let link = NSItemProvider(object: NSURL(string: "https://example.invalid/page")!)
        let richText = NSItemProvider(object: "Caption" as NSString)
        richText.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        #expect(!ComposeDroppedFile.accepts(providers: [text, link, richText]))
        #expect(ComposeDroppedFile.from(providers: [text, link, richText]).isEmpty)
    }

    @Test func failedMaterializationCanRetryAndSuccessfulReadsShareOneCopy() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Retry.txt")
        try Data("Ready".utf8).write(to: original)
        var loads = 0
        let source = ComposeDroppedFile(filename: "Named retry.txt", load: {
            loads += 1
            if loads == 1 { throw CancellationError() }
            await Task.yield()
            return original
        })
        await #expect(throws: CancellationError.self) { try await source.fileURL() }
        async let first = source.fileURL()
        async let second = source.fileURL()
        let (firstURL, secondURL) = try await (first, second)
        #expect(firstURL == secondURL)
        #expect(firstURL.lastPathComponent == "Named retry.txt")
        #expect(loads == 2)
    }

    @Test func imageOnlyPasteboardChoosesOneRepresentationAndKeepsItsBytes() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let png = Data([137, 80, 78, 71])
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(Data([73, 73]), forType: .tiff)
        #expect(ComposeDroppedFile.accepts(pasteboard))
        let sources = ComposeDroppedFile.from(pasteboard: pasteboard)
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.filename == "Dropped image.png")
        #expect(try Data(contentsOf: await source.fileURL()) == png)
        pasteboard.setString("Caption", forType: .string)
        #expect(!ComposeDroppedFile.accepts(pasteboard))
        #expect(ComposeDroppedFile.from(pasteboard: pasteboard).isEmpty)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ComposeFileDropTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func nativePromisesAreRecognizedForDragButRejectedForPaste() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let delegate = PromiseDelegate()
        let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: delegate)
        provider.userInfo = delegate
        #expect(pasteboard.writeObjects([provider]))
        #expect(ComposeDroppedFile.accepts(pasteboard))
        #expect(!ComposeDroppedFile.accepts(pasteboard, allowFilePromises: false))
        // Receiving outside a real drag callback raises an AppKit exception.
        #expect(ComposeDroppedFile.from(pasteboard: pasteboard, allowFilePromises: false).isEmpty)
    }

    @Test func oversizedFilesAreRejectedBeforeStagingAndTheBoundaryIsAllowed() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Sparse.dat")
        try Data().write(to: original)
        let handle = try FileHandle(forWritingTo: original)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(ComposeDroppedFile.maximumBytes) + 1)
        let source = ComposeDroppedFile(url: original)
        await #expect(throws: ComposeFileDropError.tooLarge) { try await source.fileURL() }
        try handle.truncate(atOffset: UInt64(ComposeDroppedFile.maximumBytes))
        let staged = try await source.fileURL()
        #expect(try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize == ComposeDroppedFile.maximumBytes)
    }

    @MainActor private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Promised notes.txt" }
        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                             completionHandler: @escaping ((any Error)?) -> Void) {
            completionHandler(CocoaError(.fileWriteUnknown))
        }
    }
}
