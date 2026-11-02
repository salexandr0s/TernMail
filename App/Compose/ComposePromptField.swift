import AppKit
import SwiftUI

/// A plain-text prompt that claims file drops before AppKit can insert paths.
struct ComposePromptField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var isFileTargeted: Bool
    let placeholder: String
    let isEditable: Bool
    let canAddFiles: Bool
    let onDrop: ([ComposeDroppedFile]) -> Void
    let onRejectedDrop: () -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void
    var onUnsupportedFilePaste: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposePromptScrollView {
        let input = ComposePromptTextView(usingTextLayoutManager: false)
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.font = .preferredFont(forTextStyle: .body)
        input.textColor = .labelColor
        input.insertionPointColor = .labelColor
        input.textContainerInset = NSSize(width: 0, height: Tokens.Space.s1)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.delegate = context.coordinator
        input.setAccessibilityLabel("Request to compose assistant")
        input.setAccessibilityHelp("Return to ask the assistant. Shift-Return for a new line. Dropped files are used only as AI context.")
        input.setAccessibilityIdentifier("compose-assistant-prompt")

        let scroll = ComposePromptScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = input
        context.coordinator.input = input
        configure(input, coordinator: context.coordinator)
        context.coordinator.updateText(text)
        return scroll
    }

    func updateNSView(_ scroll: ComposePromptScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = context.coordinator.input else { return }
        configure(input, coordinator: context.coordinator)
        context.coordinator.updateText(text)
        context.coordinator.requestFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposePromptScrollView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? Tokens.Layout.linkEditorWidth)
        guard let input = context.coordinator.input, let font = input.font else { return nil }
        let lineHeight = input.layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height
        let contents = text.isEmpty ? placeholder : text + (text.hasSuffix("\n") ? " " : "")
        let measured = (contents as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let insets = input.textContainerInset.height * 2
        return CGSize(width: width, height: ceil(min(max(measured, lineHeight), lineHeight * 3) + insets))
    }

    private func configure(_ input: ComposePromptTextView, coordinator: Coordinator) {
        input.isEditable = isEditable
        input.registerForDraggedTypes(input.acceptableDragTypes)
        input.placeholder = placeholder
        input.onSubmit = onSubmit
        input.onEscape = onEscape
        input.onFocusChange = { [weak coordinator] focused in coordinator?.reportFocus(focused) }
        input.onJoinWindow = { [weak coordinator] in coordinator?.requestFocus() }
        input.fileDrop.canAddFiles = canAddFiles
        input.fileDrop.onDrop = onDrop
        input.fileDrop.onRejectedDrop = onRejectedDrop
        input.fileDrop.onUnsupportedFilePaste = onUnsupportedFilePaste
        input.fileDrop.onTargetChanged = { [weak coordinator] in coordinator?.parent.isFileTargeted = $0 }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposePromptField
        weak var input: ComposePromptTextView?

        init(_ parent: ComposePromptField) { self.parent = parent }

        func updateText(_ text: String) {
            guard let input, input.string != text, !input.hasMarkedText() else { return }
            let selection = input.selectedRange()
            input.string = text
            let count = (text as NSString).length
            let location = min(selection.location, count)
            input.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
            input.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let input else { return }
            parent.text = input.string
            input.needsDisplay = true
        }

        func requestFocus() {
            guard parent.isFocused, parent.isEditable else { return }
            Task { @MainActor [weak self] in
                guard let self, parent.isFocused, parent.isEditable, let input, let window = input.window,
                      window.firstResponder !== input else { return }
                window.makeFirstResponder(input)
            }
        }

        func reportFocus(_ focused: Bool) {
            Task { @MainActor [weak self] in
                guard let self, let input, (input.window?.firstResponder === input) == focused else { return }
                parent.isFocused = focused
            }
        }
    }
}

/// Both the text and its scroll gutter use one routing decision. A recognized
/// file is consumed here even when the assistant cannot add it yet.
@MainActor
final class ComposePromptFileDrop {
    var canAddFiles = true
    var onDrop: ([ComposeDroppedFile]) -> Void = { _ in }
    var onRejectedDrop: () -> Void = {}
    var onUnsupportedFilePaste: () -> Void = {}
    var onTargetChanged: (Bool) -> Void = { _ in }

    func operation(_ pasteboard: NSPasteboard) -> NSDragOperation? {
        guard ComposeDroppedFile.accepts(pasteboard) else { return nil }
        onTargetChanged(true)
        return .copy
    }

    func perform(_ pasteboard: NSPasteboard, allowFilePromises: Bool = true) -> Bool? {
        guard ComposeDroppedFile.accepts(pasteboard) else { return nil }
        onTargetChanged(false)
        // AppKit can receive file promises only during a drag operation. Consume
        // promise-only clipboard contents without asking AppKit to resolve them.
        guard ComposeDroppedFile.accepts(pasteboard, allowFilePromises: allowFilePromises) else {
            onUnsupportedFilePaste()
            return true
        }
        if canAddFiles { onDrop(ComposeDroppedFile.from(pasteboard: pasteboard, allowFilePromises: allowFilePromises)) }
        else { onRejectedDrop() }
        return true
    }
}

final class ComposePromptTextView: NSTextView {
    let fileDrop = ComposePromptFileDrop()
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    var onJoinWindow: () -> Void = {}
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        Array(Set(super.acceptableDragTypes + ComposeDroppedFile.pasteboardTypes))
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onJoinWindow() }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        (placeholder as NSString).draw(in: bounds.insetBy(dx: textContainerInset.width, dy: textContainerInset.height),
            withAttributes: [.font: font ?? NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.placeholderTextColor])
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), handleReturn(modifiers: event.modifierFlags) { return }
        if event.keyCode == 53, !hasMarkedText(), string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onEscape(); return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           event.keyCode == 36 || event.keyCode == 76, handleReturn(modifiers: event.modifierFlags) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func handleReturn(modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !hasMarkedText(), !modifiers.contains(.option), !modifiers.contains(.control) else { return false }
        guard isEditable else { return true }
        if modifiers.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
        else { onSubmit() }
        return true
    }

    override func paste(_ sender: Any?) {
        if fileDrop.perform(.general, allowFilePromises: false) != nil { return }
        super.paste(sender)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let consumed = fileDrop.perform(pasteboard, allowFilePromises: false) { return consumed }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDrop.operation(sender.draggingPasteboard) ?? super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDrop.operation(sender.draggingPasteboard) ?? super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fileDrop.onTargetChanged(false); super.draggingExited(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        ComposeDroppedFile.accepts(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        fileDrop.perform(sender.draggingPasteboard) ?? super.performDragOperation(sender)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        fileDrop.onTargetChanged(false); super.concludeDragOperation(sender)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        fileDrop.onTargetChanged(false); super.draggingEnded(sender)
    }
}

final class ComposePromptScrollView: NSScrollView {
    private var prompt: ComposePromptTextView? { documentView as? ComposePromptTextView }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ComposeDroppedFile.pasteboardTypes)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        prompt?.minSize = NSSize(width: 0, height: contentSize.height)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        prompt?.fileDrop.operation(sender.draggingPasteboard) ?? super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        prompt?.fileDrop.operation(sender.draggingPasteboard) ?? super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        prompt?.fileDrop.onTargetChanged(false); super.draggingExited(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        ComposeDroppedFile.accepts(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        prompt?.fileDrop.perform(sender.draggingPasteboard) ?? super.performDragOperation(sender)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        prompt?.fileDrop.onTargetChanged(false); super.concludeDragOperation(sender)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        prompt?.fileDrop.onTargetChanged(false); super.draggingEnded(sender)
    }
}
