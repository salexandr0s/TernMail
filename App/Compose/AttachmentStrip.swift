import AppKit
import MailStore
import SwiftUI
import UniformTypeIdentifiers

/// The files attached to a draft, in a row under the message.
struct AttachmentStrip: View {
    static let chipWidth: CGFloat = 220

    let attachments: [OutgoingAttachment]
    let isEditable: Bool
    let remove: (OutgoingAttachment) -> Void

    var body: some View {
        VStack(spacing: 0) {
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }

    private func chip(_ attachment: OutgoingAttachment) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
        return HStack(spacing: Tokens.Space.s1_5) {
            HStack(spacing: Tokens.Space.s1_5) {
                Image(nsImage: Self.icon(for: attachment.filename))
                    .resizable()
                    .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
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
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s1_5)
        .frame(maxWidth: Self.chipWidth, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    private static func icon(for filename: String) -> NSImage {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
