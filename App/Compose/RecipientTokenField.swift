import AppKit
import MessageContent

/// AppKit keeps ownership of token editing; avatars occupy reserved display space.
@MainActor
final class RecipientTokenField: NSTokenField {
    static let avatarPrefix = "\u{2003}\u{2003}"
    var focusChanged: (() -> Void)?
    var didLeaveWindow: (() -> Void)?
    var avatarImage: ((EmailAddress) -> NSImage?)?
    var avatarAddresses: [EmailAddress] = [] {
        didSet { refreshAvatars() }
    }
    private var editorOverlay: RecipientAvatarOverlay?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(); refreshAvatars() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged?() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { editorOverlay?.removeFromSuperview(); editorOverlay = nil; didLeaveWindow?() }
    }

    override func layout() {
        super.layout()
        updateEditorOverlay()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard currentEditor() == nil, !avatarAddresses.isEmpty else { return }
        // Reading the inactive field's attributed value leaves active typing untouched.
        let text = NSTextStorage(attributedString: attributedStringValue)
        let layout = NSLayoutManager()
        let rect = cell?.drawingRect(forBounds: bounds) ?? bounds
        let container = NSTextContainer(size: NSSize(width: rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        text.addLayoutManager(layout)
        layout.addTextContainer(container)
        Self.drawAvatars(in: text, layout: layout, container: container,
                         origin: rect.origin, addresses: avatarAddresses, image: avatarImage)
    }

    func refreshAvatars() {
        needsDisplay = true
        updateEditorOverlay()
        editorOverlay?.needsDisplay = true
    }

    private func updateEditorOverlay() {
        guard let editor = currentEditor() as? NSTextView else {
            editorOverlay?.removeFromSuperview()
            editorOverlay = nil
            return
        }
        if editorOverlay?.superview !== editor {
            editorOverlay?.removeFromSuperview()
            let overlay = RecipientAvatarOverlay(frame: editor.bounds)
            overlay.field = self
            overlay.autoresizingMask = [.width, .height]
            editor.addSubview(overlay)
            editorOverlay = overlay
        }
    }

    static func drawAvatars(in text: NSAttributedString, layout: NSLayoutManager, container: NSTextContainer,
                            origin: NSPoint, addresses: [EmailAddress], image: ((EmailAddress) -> NSImage?)?) {
        let ranges = avatarAttachmentRanges(in: text)
        // During a native edit, metadata can lag one notification. Omit a frame rather than draw another recipient's image.
        guard ranges.count == addresses.count else { return }
        layout.ensureLayout(for: container)
        for (range, address) in zip(ranges, addresses) {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let size = min(Tokens.Space.s4, box.height)
            let frame = NSRect(x: box.minX + Tokens.Space.s1, y: box.midY - size / 2, width: size, height: size)
            RecipientAvatarDrawing.draw(image: image?(address), address: address, in: frame)
        }
    }

    static func avatarAttachmentRanges(in text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let cell = attachment.attachmentCell as? NSCell,
                  cell.stringValue.hasPrefix(avatarPrefix) else { return }
            ranges.append(range)
        }
        return ranges
    }
}

@MainActor
private final class RecipientAvatarOverlay: NSView {
    weak var field: RecipientTokenField?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let field, let editor = superview as? NSTextView,
              field.currentEditor() === editor, let text = editor.textStorage,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        RecipientTokenField.drawAvatars(in: text, layout: layout, container: container,
                                       origin: editor.textContainerOrigin, addresses: field.avatarAddresses, image: field.avatarImage)
    }
}

@MainActor
enum RecipientAvatarDrawing {
    static func draw(image: NSImage?, address: EmailAddress, in frame: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: frame).addClip()
        NSColor.windowBackgroundColor.setFill()
        frame.fill()
        if let image {
            let factor = min(frame.width / max(image.size.width, 1), frame.height / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
            image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let label = ContactAvatar.initials(name: address.name ?? "", address: address.address)
            let font = NSFont.preferredFont(forTextStyle: .caption1)
            let value = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let size = value.size()
            value.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
