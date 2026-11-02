import AppKit
import SwiftUI

/// Synthetic rows follow the same density choices without loading contacts or mail.
struct MailListAppearancePreview: View {
    let preferences: MessageListPreferences
    @AppStorage(ReadingPreferences.textScaleKey) private var textScale = 1.0
    @Environment(\.colorScheme) private var colorScheme

    private var compact: Bool { preferences.density == .compact }

    var body: some View {
        VStack(spacing: 0) {
            if preferences.showsQuickFilters {
                HStack(spacing: Tokens.Space.s3) {
                    Label("Unread", systemImage: "envelope.badge")
                    Label("Starred", systemImage: "star")
                    Label("Has Attachments", systemImage: "paperclip")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.s3)
                Divider()
            }
            row(sender: "Alex Morgan", subject: "A plan for next week", preview: "Let’s review the first draft and agree on next steps.",
                account: "Work", unread: true)
            Divider()
            row(sender: "Jordan Lee", subject: "Weekend plans", preview: "The table is booked for Saturday. See you there!",
                account: "Personal", unread: false)
        }
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message list preview with two sample messages")
    }

    private func row(sender: String, subject: String, preview: String, account: String, unread: Bool) -> some View {
        HStack(alignment: .top, spacing: compact ? Tokens.Space.s2 : Tokens.Space.s3) {
            VStack(spacing: Tokens.Space.s2) {
                TernAvatar(name: sender, size: compact ? Tokens.Control.listAvatar : Tokens.Control.avatar)
                    .accessibilityHidden(true)
                Circle().fill(unread ? Color.accentColor : .clear)
                    .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: compact ? Tokens.Space.s0_5 : Tokens.Space.s1_5) {
                HStack {
                    Text(sender).font(scaledFont(.callout, weight: unread ? .semibold : .medium)).lineLimit(1)
                    Spacer(minLength: Tokens.Space.s2)
                    Text("9:41 AM").font(scaledFont(.caption1)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(subject).font(scaledFont(compact ? .callout : .body,
                        weight: unread ? Tokens.MessageList.unreadWeight : Tokens.MessageList.readWeight))
                        .lineLimit(compact ? 1 : 2)
                    Spacer(minLength: 0)
                    if unread && preferences.showsImportance {
                        Image(systemName: "exclamationmark")
                            .foregroundStyle(Tokens.Status.important)
                            .accessibilityLabel("Important")
                    }
                }
                if !compact {
                    Text(preview).font(scaledFont(.caption1)).foregroundStyle(.secondary).lineLimit(2)
                }
                if preferences.showsAccountBadges {
                    HStack(spacing: Tokens.Space.s0_5) {
                        Circle().fill(account == "Work" ? Color.indigo : .teal)
                            .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                        Text(account).font(scaledFont(.caption2, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, compact ? Tokens.Space.s1 : Tokens.Space.s3)
        .background(Tokens.MessageList.backgroundTint(isUnread: unread, colorScheme: colorScheme))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MessageListRow.accessibilitySummary(unread: unread, sender: sender, subject: subject,
            date: "9:41 AM", messageCount: 1, starred: false, important: unread && preferences.showsImportance,
            account: preferences.showsAccountBadges ? account : nil))
    }

    private func scaledFont(_ style: NSFont.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(size: NSFont.preferredFont(forTextStyle: style).pointSize * ReadingPreferences.textScale(textScale), weight: weight)
    }
}
