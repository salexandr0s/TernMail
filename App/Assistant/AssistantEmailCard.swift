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
            VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    avatar
                    VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                        Text(sender).font(Tokens.AssistantFormatting.titleFont).lineLimit(1).help(sender)
                        if !email.senderEmail.isEmpty, sender != email.senderEmail {
                            Text(email.senderEmail).font(Tokens.AssistantFormatting.metadataFont)
                                .foregroundStyle(.secondary).lineLimit(1).help(email.senderEmail)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: Tokens.Space.s1) {
                        if let date = email.date {
                            Text(date, format: .dateTime.year().month(.abbreviated).day())
                                .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                                .fixedSize()
                                .help(date.formatted(date: .complete, time: .shortened))
                        }
                        if email.isUnread {
                            Image(systemName: "circle.fill").font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Unread")
                        }
                        if email.isStarred {
                            Image(systemName: "star.fill").foregroundStyle(Tokens.Status.star).accessibilityLabel("Starred")
                        }
                    }
                    .font(Tokens.AssistantFormatting.metadataFont)
                }
                Text(subject).font(Tokens.AssistantFormatting.titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = email.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(reason).font(Tokens.AssistantFormatting.supportingFont)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !email.snippet.isEmpty {
                    Text(email.snippet).font(Tokens.AssistantFormatting.metadataFont)
                        .foregroundStyle(.secondary).lineLimit(2).help(email.snippet)
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
                            Text("+\(email.labels.count - 3)").font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                                .help(email.labels.map(\.name).joined(separator: ", "))
                        }
                    }
                }
                HStack(spacing: Tokens.Space.s1) {
                    Text(email.accountEmail).lineLimit(1).truncationMode(.middle).help(email.accountEmail)
                    Spacer(minLength: 0)
                    if email.messageCount > 1 {
                        Label("\(email.messageCount)", systemImage: "bubble.left.and.bubble.right")
                            .accessibilityLabel("\(email.messageCount) messages")
                    }
                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }
                .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .padding(Tokens.AssistantFormatting.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius)
                    .strokeBorder(contrast == .increased ? Color.primary : (isHovered ? Color.accentColor : Tokens.Surface.border),
                                  lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
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
        .help(email.snippet.isEmpty ? "Open \(subject)" : "Open \(subject)\n\(email.snippet)")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open this conversation in Tern")
    }

    @ViewBuilder private var avatar: some View {
        if let data = email.avatarData, let image = NSImage(data: data) {
            AvatarImage(image: image, size: Tokens.Space.s6)
        } else {
            DomainLogoAvatar(address: email.senderEmail, size: Tokens.Space.s6) { TernAvatar(name: sender, size: Tokens.Space.s6) }
        }
    }

    /// The same tern: link the message list's Copy Link writes.
    private func copyLink() {
        guard let url = MailLink(accountID: email.source.accountID, threadID: email.source.threadID,
                                 messageID: email.source.messageID, partID: email.source.partID).ternURL else { return }
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
