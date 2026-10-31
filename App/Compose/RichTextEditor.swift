import AppKit
import MessageContent
import SwiftUI

/// The formatting at the selection, for the format bar and menus.
struct TextFormat: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var linkURL: URL?
    var link: Bool { linkURL != nil }
    var list: ListStyle?
}

enum ListStyle: Equatable {
    case bulleted, numbered
}

/// What the format bar and menus ask of the editor.
@MainActor
protocol RichTextEditing: AnyObject {
    func toggleBold()
    func toggleItalic()
    func toggleUnderline()
    func toggleList(_ style: ListStyle)
    /// Links the selection or the link at the cursor. At an unlinked cursor,
    /// inserts the address. Nil removes links while keeping the text.
    func setLink(_ url: URL?)
    /// Puts the cursor in the message, at its start.
    func focus()
    func insertDocument(_ document: ComposeDocument)
    func insertImage(_ reference: InlineImageReference, data: Data)
    /// The selection, in the editor view's coordinates, for a popover to point
    /// at. Nil before the editor is in a window.
    var selectionRect: CGRect? { get }
}

/// The message body editor: an `NSTextView`, since SwiftUI's rich text
/// editing needs macOS 26. It edits a `ComposeDocument` and keeps only the
/// formatting the document can hold.
struct RichTextEditor: NSViewRepresentable {
    @Binding var document: ComposeDocument
    @Binding var format: TextFormat
    var isEditable: Bool
    var font: ComposeFont = .sansSerif
    var inlineImages: [String: Data] = [:]
    /// Hands over the editor once it exists, so menus can send it commands.
    var onReady: (any RichTextEditing) -> Void
    /// Files, or an image without text, dropped or pasted into the message.
    var onAttach: ([Attachable]) -> Void
    /// Whether the cursor is in the message, which formatting applies to.
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 keeps list markers in the text, which AppKit's list
        // editing (Return continues a list, Return on an empty item ends it) relies on.
        let textView = ComposeTextView(usingTextLayoutManager: false)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Tokens.Space.s4, height: Tokens.Space.s3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = AttributedDocument.baseAttributes(font)
        textView.writingToolsBehavior = .complete
        textView.setAccessibilityLabel("Message")
        textView.onAttach = onAttach
        textView.composeFont = font
        textView.onFocusChange = onFocusChange
        textView.onInsertDocument = { [weak coordinator = context.coordinator] in coordinator?.insertDocument($0) }
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.load(document)
        onReady(context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView?.isEditable = isEditable
        if let textView = context.coordinator.textView as? ComposeTextView {
            textView.onAttach = onAttach
            textView.composeFont = font
            textView.onFocusChange = onFocusChange
        }
        if document != context.coordinator.lastDocument || font != context.coordinator.loadedFont
            || inlineImages != context.coordinator.loadedImages {
            context.coordinator.load(document)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, RichTextEditing {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        /// The document the text view shows, so updates that come back from
        /// the binding don't reset the text and selection.
        private(set) var lastDocument = ComposeDocument()
        private(set) var loadedFont: ComposeFont = .sansSerif
        private(set) var loadedImages: [String: Data] = [:]
        /// Replacing the text moves the selection, which mustn't update the
        /// format during the view update that loads it.
        private var isLoading = false

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func load(_ document: ComposeDocument) {
            guard let textView, let storage = textView.textStorage else { return }
            lastDocument = document
            loadedFont = parent.font
            loadedImages = parent.inlineImages
            isLoading = true
            storage.setAttributedString(AttributedDocument.string(from: document, font: parent.font, inlineImages: parent.inlineImages))
            textView.typingAttributes = AttributedDocument.baseAttributes(parent.font)
            isLoading = false
            textView.undoManager?.removeAllActions(withTarget: storage)
            // Loading happens while SwiftUI updates views, which mustn't change state.
            Task { @MainActor [weak self] in self?.updateFormat() }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            publish()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else { return }
            updateFormat()
        }

        // MARK: NSTextStorageDelegate

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            // Pasted text brings fonts, sizes and colors the message can't keep.
            // Text storage delegates are called on the thread editing the
            // storage, which for a text view is the main thread, so the storage
            // never crosses threads here.
            nonisolated(unsafe) let storage = textStorage
            MainActor.assumeIsolated {
                AttributedDocument.normalize(storage, in: editedRange, font: parent.font)
            }
        }

        // MARK: RichTextEditing

        func focus() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        var selectionRect: CGRect? {
            guard let textView, let window = textView.window, let host = textView.enclosingScrollView else { return nil }
            // The first line of the selection, or the caret, on screen.
            let screen = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            guard screen.height > 0 else { return nil }
            let local = host.convert(window.convertFromScreen(screen), from: nil)
            // SwiftUI measures from the top; the scroll view measures from the bottom.
            let top = host.isFlipped ? local.minY : host.bounds.height - local.maxY
            // A selection scrolled out of view still anchors inside the editor.
            let bounds = host.bounds
            return CGRect(x: min(max(local.minX, 0), bounds.width), y: min(max(top, 0), bounds.height),
                          width: min(local.width, bounds.width), height: local.height)
        }

        func toggleBold() { toggle(.boldFontMask) }
        func toggleItalic() { toggle(.italicFontMask) }

        func insertDocument(_ document: ComposeDocument) {
            guard let textView, let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            let value = AttributedDocument.string(from: document, font: parent.font, inlineImages: parent.inlineImages)
            guard textView.shouldChangeText(in: selected, replacementString: value.string) else { return }
            storage.replaceCharacters(in: selected, with: value)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: selected.location + value.length, length: 0))
        }

        func insertImage(_ reference: InlineImageReference, data: Data) {
            guard reference.isValid, let textView, let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            let value = NSAttributedString(attachment: ComposeImageAttachment(reference: reference, data: data))
            guard textView.shouldChangeText(in: selected, replacementString: value.string) else { return }
            storage.replaceCharacters(in: selected, with: value)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: selected.location + value.length, length: 0))
        }

        func toggleUnderline() {
            change { storage, range in
                let isOn = AttributedDocument.all(storage, in: range) { ($0[.underlineStyle] as? Int ?? 0) != 0 }
                if isOn {
                    storage.removeAttribute(.underlineStyle, range: range)
                } else {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            } typing: { attributes in
                let isOn = (attributes[.underlineStyle] as? Int ?? 0) != 0
                attributes[.underlineStyle] = isOn ? nil : NSUnderlineStyle.single.rawValue
            }
        }

        func setLink(_ url: URL?) {
            guard let textView, let storage = textView.textStorage else { return }
            var range = textView.selectedRange()
            if range.length == 0, storage.length > 0 {
                let location = min(range.location, storage.length - 1)
                var linkedRange = NSRange()
                let link = storage.attribute(
                    .link, at: location, longestEffectiveRange: &linkedRange,
                    in: NSRange(location: 0, length: storage.length)
                )
                if link != nil, range.location < storage.length || textView.typingAttributes[.link] != nil {
                    range = linkedRange
                }
            }
            if range.length == 0 {
                guard let url else { return }
                var attributes = textView.typingAttributes
                attributes[.link] = url
                let text = NSAttributedString(string: url.absoluteString, attributes: attributes)
                guard textView.shouldChangeText(in: range, replacementString: text.string) else { return }
                storage.replaceCharacters(in: range, with: text)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: range.location + text.length, length: 0))
            } else {
                guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
                storage.beginEditing()
                if let url {
                    storage.addAttribute(.link, value: url, range: range)
                } else {
                    storage.removeAttribute(.link, range: range)
                }
                storage.endEditing()
                textView.didChangeText()
                var attributes = textView.typingAttributes
                attributes[.link] = url
                textView.typingAttributes = attributes
            }
            updateFormat()
        }

        func toggleList(_ style: ListStyle) {
            guard let textView, let storage = textView.textStorage else { return }
            var document = AttributedDocument.document(from: storage)
            let selection = textView.selectedRange()
            let start = AttributedDocument.position(of: selection.location, in: storage)
            let end = AttributedDocument.position(of: NSMaxRange(selection), in: storage)
            let indexes = start.block...end.block
            let removing = indexes.allSatisfy { index in
                switch document.blocks[index].kind {
                case .bulleted: style == .bulleted
                case .numbered: style == .numbered
                case .paragraph: false
                }
            }
            for index in indexes {
                document.blocks[index].kind = switch (removing, style) {
                case (true, _): .paragraph
                case (false, .bulleted): .bulleted(level: 0)
                case (false, .numbered): .numbered(level: 0)
                }
            }
            let text = AttributedDocument.string(from: document, font: parent.font, inlineImages: parent.inlineImages)
            let whole = NSRange(location: 0, length: storage.length)
            guard textView.shouldChangeText(in: whole, replacementString: text.string) else { return }
            storage.replaceCharacters(in: whole, with: text)
            textView.didChangeText()
            let from = AttributedDocument.location(of: start, in: storage)
            let to = AttributedDocument.location(of: end, in: storage)
            textView.setSelectedRange(NSRange(location: from, length: max(0, to - from)))
            updateFormat()
        }

        // MARK: Private

        private func toggle(_ trait: NSFontTraitMask) {
            let manager = NSFontManager.shared
            change { storage, range in
                let isOn = AttributedDocument.all(storage, in: range) { attributes in
                    (attributes[.font] as? NSFont).map { manager.traits(of: $0).contains(trait) } ?? false
                }
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let font = value as? NSFont ?? AttributedDocument.baseFont
                    let changed = isOn ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
                    storage.addAttribute(.font, value: changed, range: subrange)
                }
            } typing: { attributes in
                let font = attributes[.font] as? NSFont ?? AttributedDocument.baseFont
                let isOn = manager.traits(of: font).contains(trait)
                attributes[.font] = isOn ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            }
        }

        /// Applies an attribute change to the selection as one undoable step,
        /// or to the typing attributes when nothing is selected.
        private func change(
            _ apply: (NSTextStorage, NSRange) -> Void,
            typing: (inout [NSAttributedString.Key: Any]) -> Void
        ) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            if range.length == 0 {
                var attributes = textView.typingAttributes
                typing(&attributes)
                textView.typingAttributes = attributes
            } else {
                guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
                storage.beginEditing()
                apply(storage, range)
                storage.endEditing()
                textView.didChangeText()
            }
            updateFormat()
        }

        private func publish() {
            guard let storage = textView?.textStorage else { return }
            let document = AttributedDocument.document(from: storage)
            lastDocument = document
            if parent.document != document { parent.document = document }
        }

        private func updateFormat() {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            let attributes: [NSAttributedString.Key: Any] = if range.length == 0 || range.location >= storage.length {
                textView.typingAttributes
            } else {
                storage.attributes(at: range.location, effectiveRange: nil)
            }
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let paragraph = range.location < storage.length
                ? storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : attributes[.paragraphStyle] as? NSParagraphStyle
            let link = range.location < storage.length
                ? storage.attribute(.link, at: range.location, effectiveRange: nil)
                : attributes[.link]
            let format = TextFormat(
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                linkURL: (link as? URL) ?? (link as? String).flatMap { URL(string: $0) },
                list: paragraph?.textLists.last.map { AttributedDocument.isNumbered($0) ? .numbered : .bulleted }
            )
            if parent.format != format { parent.format = format }
        }
    }
}
