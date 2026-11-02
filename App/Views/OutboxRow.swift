import MailStore
import SwiftUI

/// A pending message exposes recovery actions without leaving the native list.
struct OutboxRow: View {
    let activity: DraftActivity
    let onOpen: () -> Void
    let onCancelSend: (() -> Void)?

    var body: some View {
        let draft = activity.draft
        let status = self.status
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    Text(recipients)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(recipients)
                    Spacer(minLength: 0)
                    Text(ThreadDate.short(draft.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(draft.subject.isEmpty ? "No Subject" : draft.subject)
                    .font(.headline)
                    .lineLimit(2)
                    .help(draft.subject)
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    Image(systemName: status.icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                        .background(status.tint.opacity(Tokens.Opacity.wash), in: .rect(cornerRadius: Tokens.Radius.sm))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(status.title)
                            .font(.callout.weight(.semibold))
                        if let detail = status.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .help(detail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: Tokens.Space.s3) {
                Button("Open", systemImage: "arrow.up.forward.square", action: onOpen)
                    .help("Open this message in Compose")
                if let onCancelSend {
                    Button("Cancel Send", systemImage: "arrow.uturn.backward", action: onCancelSend)
                        .help("Cancel this queued send and reopen the draft")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, Tokens.Space.s3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outbox.message.\(activity.id)")
    }

    private var recipients: String {
        let draft = activity.draft
        let names = (draft.to + draft.cc + draft.bcc).map { address in
            address.name.flatMap { $0.isEmpty ? nil : $0 } ?? address.address
        }
        return names.isEmpty ? "No Recipients" : names.formatted(.list(type: .and))
    }

    private var status: (title: String, detail: String?, icon: String, tint: Color) {
        if let error = activity.draft.sendError {
            return ("Not Sent", error, "exclamationmark.triangle", Tokens.Status.error)
        }
        if activity.isWaitingToRetry {
            return ("Retrying", "Can't reach Gmail. Tern will keep trying.", "arrow.clockwise", Tokens.Status.warning)
        }
        if activity.rows.contains(where: { $0.kind == .sendDraft && $0.state == .sending }) {
            return ("Sending…", nil, "paperplane", .accentColor)
        }
        return ("Waiting to Send", nil, "clock", .secondary)
    }
}
