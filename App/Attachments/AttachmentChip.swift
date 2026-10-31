import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file's icon, name and size, with a control after them. With `open`,
/// clicking the icon or name opens the file in Quick Look.
struct AttachmentChip<Accessory: View>: View {
    static var width: CGFloat { Tokens.Layout.attachmentWidth }

    let filename: String
    let size: Int
    let isLoading: Bool
    let open: (() -> Void)?
    let accessory: Accessory
    @State private var isHovered = false

    init(
        filename: String,
        size: Int,
        isLoading: Bool = false,
        open: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.filename = filename
        self.size = size
        self.isLoading = isLoading
        self.open = open
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            if let open {
                Button(action: open) { label }
                    .buttonStyle(.plain)
                    .help("Open in Quick Look")
                    .accessibilityLabel("Open \(filename)")
                    .accessibilityHint("Opens in Quick Look")
            } else {
                label
            }
            accessory
        }
        .padding(Tokens.Space.s1)
        .frame(maxWidth: Self.width, alignment: .leading)
        .ternSurface()
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(isHovered && open != nil ? Color.accentColor : .clear, lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .ternAnimation(value: isHovered)
    }

    private var label: some View {
        HStack(spacing: Tokens.Space.s2) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(nsImage: Self.icon(for: filename))
                        .resizable()
                }
            }
            .frame(width: Tokens.Control.avatar, height: Tokens.Control.avatar)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text(filename)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(filename)
                Text(isLoading ? "Downloading…" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private static func icon(for filename: String) -> NSImage {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
