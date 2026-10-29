import AppKit
import MailStore
import SwiftUI
import UniformTypeIdentifiers

/// The files attached to a draft, in a row under the message.
struct AttachmentStrip: View {
    let attachments: [OutgoingAttachment]
    let isEditable: Bool
    let remove: (OutgoingAttachment) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    ForEach(attachments) { attachment in
                        AttachmentChip(filename: attachment.filename, size: attachment.size) {
                            if isEditable {
                                Button {
                                    remove(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(attachment.filename)")
                                .accessibilityLabel("Remove \(attachment.filename)")
                            }
                        }
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
            }
            .scrollIndicators(.automatic)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }
}

/// A file's icon, name and size, with a control after them. In a received
/// message, clicking the icon or name opens the file.
struct AttachmentChip<Accessory: View>: View {
    static var width: CGFloat { 220 }

    let filename: String
    let size: Int
    let isLoading: Bool
    let open: (() -> Void)?
    let accessory: Accessory

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
        HStack(spacing: Tokens.Space.s1_5) {
            if let open {
                Button(action: open) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
            accessory
        }
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s1_5)
        .frame(maxWidth: Self.width, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    private var label: some View {
        HStack(spacing: Tokens.Space.s1_5) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(nsImage: Self.icon(for: filename))
                        .resizable()
                }
            }
            .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
            VStack(alignment: .leading, spacing: 0) {
                Text(filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
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
