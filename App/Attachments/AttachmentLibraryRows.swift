import AppKit
import MailStore
import MessageContent
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentLibraryRow: View {
    let item: AttachmentLibraryItem
    let accountName: String
    let accounts: [AccountRecord]
    var compact = false

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            AttachmentFileIcon(item: item, size: Tokens.Control.avatarLarge)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                HStack(spacing: Tokens.Space.s2) {
                    Text(item.filename).font(.body.weight(.medium)).lineLimit(1)
                        .truncationMode(.middle).help(item.filename)
                    if item.category != .uncategorized {
                        Text(item.category.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(item.subject)
                if compact {
                    HStack(spacing: Tokens.Space.s2) {
                        AttachmentSenderAvatar(sender: item.sender, accounts: accounts, size: Tokens.Space.s5)
                        Text(AttachmentPresentation.senderName(item.sender)).lineLimit(1)
                        Text("·")
                        Text(item.date, format: .dateTime.day().month().year())
                        Spacer(minLength: 0)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: Tokens.Space.s2) {
                    Text(AttachmentPresentation.format(item))
                    Text(AttachmentPresentation.size(item.size))
                    if compact { Text("·"); Text(accountName).lineLimit(1) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                HStack(spacing: Tokens.Space.s2) {
                    AttachmentSenderAvatar(sender: item.sender, accounts: accounts)
                    Text(AttachmentPresentation.senderName(item.sender))
                        .lineLimit(2).help(item.sender)
                }
                .frame(width: Tokens.Layout.sidebarMinWidth, alignment: .leading)
                VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                    Text(item.date, format: .dateTime.day().month().year())
                    Text(accountName).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(accountName)
                }
                .font(.caption)
                .frame(width: Tokens.Space.s16 * 2, alignment: .trailing)
            }
        }
        .padding(.vertical, Tokens.Space.s2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AttachmentPresentation.accessibilityLabel(item, account: accountName))
    }
}

struct AttachmentLibraryCard: View {
    let item: AttachmentLibraryItem
    let accountName: String
    let accounts: [AccountRecord]
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .fill(Tokens.Surface.muted)
                AttachmentFileIcon(item: item, size: Tokens.Space.s16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(AttachmentPresentation.format(item))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.trailing, Tokens.Space.s8)
                    .padding(Tokens.Space.s3)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.title3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(Tokens.Space.s3)
                    .accessibilityHidden(true)
            }
            .frame(height: Tokens.Space.s16 * 2)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(item.filename).font(.body.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle).help(item.filename)
                Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(item.subject)
            }
            HStack(spacing: Tokens.Space.s2) {
                AttachmentSenderAvatar(sender: item.sender, accounts: accounts)
                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                    Text(AttachmentPresentation.senderName(item.sender))
                        .font(.caption.weight(.medium)).lineLimit(1).help(item.sender)
                    Text(accountName).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(accountName)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(item.date, format: .dateTime.day().month().year())
                Spacer(minLength: Tokens.Space.s1)
                Text(AttachmentPresentation.size(item.size))
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(item.category == .uncategorized ? "No category" : item.category.title)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(Tokens.Space.s3)
        .ternSurface()
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus)
        }
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AttachmentPresentation.accessibilityLabel(item, account: accountName))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct AttachmentFileIcon: View {
    let item: AttachmentLibraryItem
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: fileType))
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var fileType: UTType {
        UTType(filenameExtension: item.fileExtension) ?? UTType(mimeType: item.mimeType) ?? .data
    }
}

private struct AttachmentSenderAvatar: View {
    let sender: String
    let accounts: [AccountRecord]
    var size = Tokens.Control.avatar

    var body: some View {
        if let account = matchingAccount, let image = AccountProfileImages.shared.image(for: account.id) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle()).accessibilityHidden(true)
        } else {
            TernAvatar(name: sender, size: size)
        }
    }

    private var matchingAccount: AccountRecord? {
        let address = EmailAddress.parseList(sender).first?.address.lowercased()
        return accounts.first { $0.email.lowercased() == address }
    }
}

enum AttachmentPresentation {
    static func senderName(_ sender: String) -> String {
        guard let parsed = EmailAddress.parseList(sender).first else { return sender }
        return parsed.name?.isEmpty == false ? parsed.name ?? parsed.address : parsed.address
    }

    static func format(_ item: AttachmentLibraryItem) -> String {
        item.fileExtension.isEmpty ? item.mimeType : item.fileExtension.uppercased()
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func accessibilityLabel(_ item: AttachmentLibraryItem, account: String) -> String {
        "\(item.filename), \(format(item)), \(size(item.size)), from \(item.sender), \(item.date.formatted(date: .abbreviated, time: .omitted)), \(account), email \(item.subject), \(item.category.title)"
    }
}
