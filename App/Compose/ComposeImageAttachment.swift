import AppKit
import ImageIO
import MessageContent

/// An inline image as the editor draws it, at the size it shows it. Decoding
/// a large image takes long enough to stall typing, so the model makes this
/// off the main actor before it hands the image to the editor.
struct ComposeImagePreview: Sendable {
    /// How large the editor shows an image. It is read on the main actor and
    /// handed to the decode, which runs off it.
    struct Display: Sendable {
        /// Used when no screen is attached.
        private static let fallbackScale: CGFloat = 2

        /// The widest the editor shows an image, in points.
        let maxWidth: CGFloat
        /// Pixels per point on the sharpest attached screen.
        let scale: CGFloat

        @MainActor static var current: Display {
            Display(maxWidth: Tokens.Layout.attachmentWidth,
                    scale: NSScreen.screens.map(\.backingScaleFactor).max() ?? fallbackScale)
        }
    }

    let image: CGImage
    /// The image's size in the message, in points.
    let size: CGSize
    /// The type of the image's data, such as `public.jpeg`.
    let typeIdentifier: String?

    /// The size the editor gives an image whose own size is `size`.
    static func shownSize(for size: CGSize, maxWidth: CGFloat) -> CGSize {
        let scale = min(1, maxWidth / size.width)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The type of image `data` holds, read from its header. Nil when it isn't an image.
    static func typeIdentifier(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source).map { $0 as String }
    }

    /// Decodes `data` on the calling thread. Nil when it isn't an image.
    init?(data: Data, display: Display) {
        // `NSImage` reads only the header here. Its size follows the image's
        // resolution and rotation, as the thumbnail below does.
        guard let full = NSImage(data: data)?.size, full.width > 0, full.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let size = Self.shownSize(for: full, maxWidth: display.maxWidth)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // A pixel for each one the screen shows, so the preview looks
            // like the full image drawn at this size.
            kCGImageSourceThumbnailMaxPixelSize: (max(size.width, size.height) * display.scale).rounded(.up),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        self.image = image
        self.size = size
        typeIdentifier = CGImageSourceGetType(source).map { $0 as String }
    }

    /// Decodes `data` off the main actor.
    static func decoded(from data: Data, display: Display) async -> ComposeImagePreview? {
        await Task.detached(priority: .userInitiated) { ComposeImagePreview(data: data, display: display) }.value
    }
}

/// The attachment carries its CID through editing and Undo, independent of
/// its preview. It keeps the image's data, so copying or dragging the image
/// out of the message gives the original, and draws a preview in its place.
final class ComposeImageAttachment: NSTextAttachment {
    /// For data that isn't an image the system can read.
    private static let fallbackType = "public.png"

    let reference: InlineImageReference
    /// What the editor draws for the data. Setting `image` would make the
    /// attachment drop its data, so this is returned from `image(forBounds:)`.
    private let drawn: NSImage?

    /// Without a `preview`, the image is read from `data` here and decoded
    /// when the editor first draws it.
    init(reference: InlineImageReference, data: Data?, preview: ComposeImagePreview? = nil) {
        self.reference = reference
        let shown: NSImage?
        let size: CGSize?
        if let preview {
            shown = NSImage(cgImage: preview.image, size: preview.size)
            size = preview.size
        } else {
            shown = data.flatMap(NSImage.init(data:))
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: reference.altText)
            size = shown.map { ComposeImagePreview.shownSize(for: $0.size, maxWidth: Tokens.Layout.attachmentWidth) }
        }
        drawn = data == nil ? nil : shown
        let type = preview?.typeIdentifier ?? data.flatMap(ComposeImagePreview.typeIdentifier(of:)) ?? Self.fallbackType
        super.init(data: data, ofType: type)
        // Without data there is nothing to keep, so the placeholder is the attachment's own image.
        if data == nil { image = shown }
        if let size, size.width > 0, size.height > 0 { bounds = NSRect(origin: .zero, size: size) }
    }

    required init?(coder: NSCoder) { return nil }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> NSImage? {
        drawn ?? super.image(forBounds: imageBounds, textContainer: textContainer, characterIndex: charIndex)
    }
}
