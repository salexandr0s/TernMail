import AppKit
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Tern

@Suite @MainActor struct ComposePromptFieldTests {
    @Test func filesUseTheContextCallbackOnceAndNeverInsertTheirPath() {
        let input = Self.input()
        input.string = "Summarize this"
        input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = FileManager.default.temporaryDirectory.appending(path: "prompt-context.pdf")
        #expect(pasteboard.writeObjects([url as NSURL]))
        pasteboard.setString(url.path, forType: .string)
        var calls = 0
        var received: [ComposeDroppedFile] = []
        var rejected = 0
        input.fileDrop.onDrop = { calls += 1; received = $0 }
        input.fileDrop.onRejectedDrop = { rejected += 1 }

        #expect(input.fileDrop.operation(pasteboard) == .copy)
        #expect(calls == 0)
        #expect(input.readSelection(from: pasteboard, type: .string))
        #expect(calls == 1 && received.count == 1)
        #expect(input.string == "Summarize this")
        #expect(input.fileDrop.perform(pasteboard) == true)
        #expect(calls == 2 && received.count == 1)
        #expect(input.string == "Summarize this")

        input.fileDrop.canAddFiles = false
        input.isEditable = false
        #expect(input.readSelection(from: pasteboard, type: .string))
        #expect(calls == 2 && rejected == 1)
        #expect(input.string == "Summarize this")
    }

    @Test func ordinaryTextAndWebURLsStillInsertAsPromptText() throws {
        let input = Self.input()
        input.fileDrop.onDrop = { _ in Issue.record("Prompt text was treated as file context") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Please compare these", forType: .string)
        #expect(input.fileDrop.perform(pasteboard) == nil)
        #expect(input.readSelection(from: pasteboard, type: .string))
        #expect(input.string == "Please compare these")

        pasteboard.clearContents()
        let url = try #require(URL(string: "https://example.invalid/reference.pdf"))
        #expect(pasteboard.writeObjects([url as NSURL]))
        pasteboard.setString(url.absoluteString, forType: .string)
        input.setSelectedRange(NSRange(location: 0, length: input.string.utf16.count))
        #expect(input.fileDrop.operation(pasteboard) == nil)
        #expect(input.readSelection(from: pasteboard, type: .string))
        #expect(input.string == url.absoluteString)
    }

    @Test func promisedFilePasteIsConsumedWithoutRequestingTheFile() {
        let input = Self.input()
        input.string = "Summarize this"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let delegate = PromiseDelegate()
        let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: delegate)
        provider.userInfo = delegate
        #expect(pasteboard.writeObjects([provider]))
        var drops = 0
        var unsupported = 0
        input.fileDrop.onDrop = { _ in drops += 1 }
        input.fileDrop.onUnsupportedFilePaste = { unsupported += 1 }

        #expect(input.fileDrop.perform(pasteboard, allowFilePromises: false) == true)
        #expect(unsupported == 1 && drops == 0)
        #expect(delegate.writeCount == 0)
        // The native paste path must opt out as well; receiving promises here
        // would raise an AppKit exception because this is not a drag callback.
        #expect(input.readSelection(from: pasteboard, type: .fileURL))
        #expect(unsupported == 2 && drops == 0)
        #expect(delegate.writeCount == 0)
        #expect(input.string == "Summarize this")
    }

    @Test func returnSubmitsButShiftReturnAndCompositionDoNot() {
        let input = Self.input()
        input.string = "Draft a reply"
        input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        var submissions = 0
        input.onSubmit = { submissions += 1 }
        #expect(input.handleReturn(modifiers: []))
        #expect(input.handleReturn(modifiers: [.command]))
        #expect(submissions == 2)
        #expect(input.handleReturn(modifiers: [.shift]))
        #expect(input.string == "Draft a reply\n")
        #expect(submissions == 2)
        #expect(!input.handleReturn(modifiers: [.option]))
        #expect(!input.handleReturn(modifiers: [.control]))

        input.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        #expect(!input.handleReturn(modifiers: []))
        #expect(submissions == 2)
        input.unmarkText()
        input.isEditable = false
        #expect(input.handleReturn(modifiers: []))
        #expect(submissions == 2)
    }

    @Test func updatesPreserveSelectionAndRespectFocusAndMarkedText() async throws {
        var text = "Rewrite this paragraph"
        var focused = false
        let field = ComposePromptField(text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }), isFileTargeted: .constant(false),
            placeholder: "Ask", isEditable: true, canAddFiles: true,
            onDrop: { _ in }, onRejectedDrop: {}, onSubmit: {}, onEscape: {})
        let coordinator = field.makeCoordinator()
        let input = Self.input()
        coordinator.input = input
        input.delegate = coordinator
        coordinator.updateText(text)
        let selection = NSRange(location: 8, length: 4)
        input.setSelectedRange(selection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        content.addSubview(input)
        let other = NSTextField(frame: NSRect(x: 0, y: 130, width: 400, height: 30))
        content.addSubview(other)
        #expect(window.makeFirstResponder(other))
        coordinator.updateText(text)
        coordinator.requestFocus()
        await Task.yield()
        #expect(window.firstResponder !== input)
        #expect(input.selectedRange() == selection)

        focused = true
        coordinator.requestFocus()
        await Task.yield()
        #expect(window.firstResponder === input)
        #expect(input.selectedRange() == selection)
        coordinator.updateText("Short")
        #expect(input.selectedRange() == NSRange(location: 5, length: 0))
        #expect(window.firstResponder === input)

        input.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = input.string
        coordinator.updateText("External update")
        #expect(input.hasMarkedText())
        #expect(input.string == composing)
        input.unmarkText()
    }

    private static func input() -> ComposePromptTextView {
        let input = ComposePromptTextView(usingTextLayoutManager: false)
        input.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        input.isRichText = false
        input.isEditable = true
        input.font = .systemFont(ofSize: NSFont.systemFontSize)
        return input
    }

    @MainActor private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        private nonisolated let writes = Mutex(0)
        var writeCount: Int { writes.withLock { $0 } }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            "Promised notes.txt"
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                             completionHandler: @escaping ((any Error)?) -> Void) {
            writes.withLock { $0 += 1 }
            Issue.record("Clipboard paste requested a promised file outside a drag callback")
            completionHandler(CocoaError(.fileWriteUnknown))
        }
    }
}
