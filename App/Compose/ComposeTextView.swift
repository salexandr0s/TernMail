import AppKit
import MessageContent

/// Reads text from the pasteboard and routes files and images to compose.
final class ComposeTextView: NSTextView {
    var onAttach: (([Attachable]) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onInsertDocument: ((ComposeDocument) -> Void)?
    var composeFont: ComposeFont = .sansSerif

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { reportFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { reportFocus(false) }
        return resigned
    }

    /// Focus can move while SwiftUI updates views, which mustn't change state.
    private func reportFocus(_ isFocused: Bool) {
        Task { @MainActor [weak self] in self?.onFocusChange?(isFocused) }
    }

    /// Rich text from other apps and web pages keeps the formatting the message can hold.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.rtf, .html, .string, .URL]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let items = Self.attachables(on: pasteboard) { onAttach?(items); return }
        if ComposePreferences.markdown, pasteboard.data(forType: .rtf) == nil, Self.htmlDocument(on: pasteboard) == nil,
           let text = pasteboard.string(forType: .string) {
            onInsertDocument?(MarkdownConverter.document(from: text))
            return
        }
        super.paste(sender)
    }

    /// AppKit reads HTML with WebKit, which can load remote images, so paste
    /// and drop read it with the importer drafts use.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .html else { return super.readSelection(from: pboard, type: type) }
        guard let document = Self.htmlDocument(on: pboard) else { return super.readSelection(from: pboard, type: .string) }
        onInsertDocument?(document)
        return true
    }

    /// The HTML on the pasteboard as message text, unless the plain text beside
    /// it says the same. HTML without a list, a link or styled text reads as
    /// plain text, which keeps spacing the HTML set with styles, as code from
    /// an editor does.
    private static func htmlDocument(on pasteboard: NSPasteboard) -> ComposeDocument? {
        guard let html = pasteboard.string(forType: .html) else { return nil }
        let document = HTMLImporter.importHTML(html, detachingQuote: false).document
        let isFormatted = document.blocks.contains { block in
            block.kind != .paragraph || block.runs.contains { $0.bold || $0.italic || $0.underline || $0.link != nil }
        }
        return isFormatted || pasteboard.availableType(from: [.string]) == nil ? document : nil
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        guard ComposePreferences.markdown, let inserted = insertString as? String,
              inserted == " " || inserted == "\n" || inserted == "*" || inserted == "_" || inserted == ")",
              let storage = textStorage, selectedRange().length == 0, storage.length > 0 else { return }
        let string = storage.string as NSString
        let caret = min(selectedRange().location, string.length)
        guard caret > 0 else { return }
        let paragraph = string.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        var plainStart = paragraph.location
        var usable = true
        storage.enumerateAttributes(in: NSRange(location: paragraph.location, length: caret - paragraph.location)) { attributes, range, _ in
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let styled = traits.contains(.boldFontMask) || traits.contains(.italicFontMask)
                || (attributes[.underlineStyle] as? Int ?? 0) != 0 || attributes[.link] != nil || attributes[.attachment] != nil
            if styled { plainStart = NSMaxRange(range) }
            if NSMaxRange(range) >= caret { usable = !styled }
        }
        guard usable, plainStart < caret else { return }
        let range = NSRange(location: plainStart, length: caret - plainStart)
        let raw = string.substring(with: range)
        let candidate = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        let converted = MarkdownConverter.document(from: candidate)
        guard converted.blocks.count == 1, let block = converted.blocks.first,
              block.text != candidate || (plainStart == paragraph.location && block.kind != .paragraph) else { return }
        let previousTyping = typingAttributes
        let existingStyle = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
        let value = NSMutableAttributedString(attributedString: AttributedDocument.string(from: converted, font: composeFont))
        if block.kind == .paragraph, let existingStyle { value.addAttribute(.paragraphStyle, value: existingStyle, range: NSRange(location: 0, length: value.length)) }
        if raw.hasSuffix("\n") { value.append(NSAttributedString(string: "\n", attributes: previousTyping)) }
        guard shouldChangeText(in: range, replacementString: value.string) else { return }
        storage.replaceCharacters(in: range, with: value)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + value.length, length: 0))
        var nextTyping = previousTyping
        if block.kind != .paragraph, value.length > 0 {
            nextTyping[.paragraphStyle] = value.attribute(.paragraphStyle, at: value.length - 1, effectiveRange: nil)
        }
        typingAttributes = nextTyping
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.attachables(on: sender.draggingPasteboard) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.attachables(on: sender.draggingPasteboard) == nil ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable, let items = Self.attachables(on: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onAttach?(items)
        return true
    }

    /// Files on the pasteboard, or an image with no text beside it, as from a screenshot.
    private static func attachables(on pasteboard: NSPasteboard) -> [Attachable]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.map(Attachable.file)
        }
        guard pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
        if let png = pasteboard.data(forType: .png) {
            return [.data(png, filename: "Pasted Image.png", mimeType: "image/png")]
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.data(png, filename: "Pasted Image.png", mimeType: "image/png")]
        }
        return nil
    }
}
