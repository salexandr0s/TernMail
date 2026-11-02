import SwiftUI
import SyncEngine

/// Uses only metadata already included in the review, without loading a message.
struct MailOrganizationExampleRow: View {
    let message: MailOrganizationSample

    private var preview: String {
        message.snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                Label(message.isSent ? "Sent" : "Received",
                      systemImage: message.isSent ? "arrow.up.right" : "arrow.down.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(message.sender.isEmpty ? "Unknown sender" : message.sender)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message.sender)
                Spacer(minLength: 0)
                if let date = message.date {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help(date.formatted(date: .complete, time: .shortened))
                }
            }
            Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .help(message.subject)
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}
