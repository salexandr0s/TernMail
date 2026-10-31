import AppKit
import MessageContent
import SwiftUI

struct AssistantEmailCard: View {
    let email: AssistantEmailResult
    let onOpen: (AssistantSource) -> Void
    let onOpenInNewWindow: (AssistantSource) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        Button { onOpen(email.source) } label: {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    avatar
                    VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                        Text(sender).font(.callout.weight(.semibold)).lineLimit(1)
                        if !email.senderEmail.isEmpty, sender != email.senderEmail {
                            Text(email.senderEmail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                        if let date = email.date {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        if email.isUnread {
                            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Unread")
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(subject).font(.callout.weight(.semibold)).lineLimit(2)
                    if email.isStarred {
                        Image(systemName: "star.fill").foregroundStyle(Tokens.Status.star).accessibilityLabel("Starred")
                    }
                }
                if let reason = email.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(reason).font(.callout).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !email.snippet.isEmpty {
                    Text(email.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !email.labels.isEmpty {
                    FlowLayout(spacing: Tokens.Space.s1) {
                        ForEach(email.labels.prefix(3), id: \.id) { label in
                            let icon = LabelAppearance.shared.icon(for: label)
                            TernBadge(text: label.name, systemImage: icon == "tag" ? "tag.fill" : icon,
                                      tint: Color(gmailHex: label.backgroundColor) ?? .secondary)
                        }
                        if email.labels.count > 3 {
                            Text("+\(email.labels.count - 3)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                HStack(spacing: Tokens.Space.s1) {
                    Text(email.accountEmail).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if email.messageCount > 1 {
                        Label("\(email.messageCount)", systemImage: "bubble.left.and.bubble.right")
                            .accessibilityLabel("\(email.messageCount) messages")
                    }
                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(contrast == .increased ? Color.primary : (isHovered ? Color.accentColor : Tokens.Surface.border),
                                  lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .onHover { isHovered = $0 }
        .ternAnimation(value: isHovered)
        .contextMenu {
            Group {
                Button("Open", systemImage: "envelope.open") { onOpen(email.source) }
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { onOpenInNewWindow(email.source) }
                Divider()
                Button("Copy Link", systemImage: "link") { copyLink() }
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Open \(subject)")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open this conversation in Tern")
    }

    @ViewBuilder private var avatar: some View {
        if let data = email.avatarData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: Tokens.Control.avatar, height: Tokens.Control.avatar)
                .clipShape(Circle()).accessibilityHidden(true)
        } else {
            DomainLogoAvatar(address: email.senderEmail) { TernAvatar(name: sender) }
        }
    }

    /// The same tern: link the message list's Copy Link writes.
    private func copyLink() {
        guard let url = MailLink(accountID: email.source.accountID, threadID: email.source.threadID).ternURL else { return }
        NSPasteboard.general.replaceContents(with: url.absoluteString)
    }

    private var sender: String {
        let value = email.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (email.senderEmail.isEmpty ? "Unknown sender" : email.senderEmail) : value
    }

    private var subject: String {
        let value = email.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "No Subject" : value
    }
}
