import MailStore
import SwiftUI

/// The files attached to a draft, in a row under the message.
struct AttachmentStrip: View {
    let attachments: [OutgoingAttachment]
    let isEditable: Bool
    let remove: (OutgoingAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    ForEach(attachments) { attachment in
                        AttachmentChip(filename: attachment.filename, size: attachment.size) {
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
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
            }
            .scrollIndicators(.automatic)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Tokens.Surface.muted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }
}
