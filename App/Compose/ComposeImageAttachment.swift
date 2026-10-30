import AppKit
import MessageContent

/// The attachment carries its CID through editing and Undo, independent of its preview.
final class ComposeImageAttachment: NSTextAttachment {
    let reference: InlineImageReference

    init(reference: InlineImageReference, data: Data?) {
        self.reference = reference
        super.init(data: data, ofType: "public.png")
        let preview = data.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: reference.altText)
        image = preview
        if let size = preview?.size, size.width > 0, size.height > 0 {
            let scale = min(1, Tokens.Layout.attachmentWidth / size.width)
            bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        }
    }

    required init?(coder: NSCoder) { return nil }
}
