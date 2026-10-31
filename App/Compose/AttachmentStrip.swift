import AppKit
import MailStore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The files attached to a draft, in a row under the message. Clicking one
/// opens it in Quick Look; dragging one out copies the file.
struct AttachmentStrip: View {
    let attachments: [OutgoingAttachment]
    let isEditable: Bool
    /// A copy of the file under its own name, or nil when it can't be read.
    let fileURL: @MainActor (OutgoingAttachment) async -> URL?
    let remove: (OutgoingAttachment) -> Void
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    ForEach(attachments) { attachment in
                        chip(attachment)
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
            }
            .scrollIndicators(.automatic)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Tokens.Surface.muted)
        .quickLookPreview($previewURL)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }

    private func chip(_ attachment: OutgoingAttachment) -> some View {
        AttachmentChip(filename: attachment.filename, size: attachment.size, open: { preview(attachment) }) {
            if isEditable {
                Button {
                    remove(attachment)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                }
                .buttonStyle(.borderless)
                .help("Remove \(attachment.filename)")
                .accessibilityLabel("Remove \(attachment.filename)")
            }
        }
        .draggable(OutgoingAttachmentTransfer { await fileURL(attachment) })
        .contextMenu {
            Button("Quick Look") { preview(attachment) }
            Button("Show in Finder") { reveal(attachment) }
            if isEditable {
                Divider()
                Button("Remove", role: .destructive) { remove(attachment) }
            }
        }
    }

    private func preview(_ attachment: OutgoingAttachment) {
        Task { previewURL = await fileURL(attachment) }
    }

    private func reveal(_ attachment: OutgoingAttachment) {
        Task {
            guard let url = await fileURL(attachment) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Drags an attachment out as a file, which is written once the drop lands.
struct OutgoingAttachmentTransfer: Transferable {
    let file: @MainActor () async -> URL?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { transfer in
            guard let url = await transfer.file() else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(url)
        }
    }
}

/// A file's icon, name and size, with a control after them. In a received
/// message, clicking the icon or name opens the file.
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
