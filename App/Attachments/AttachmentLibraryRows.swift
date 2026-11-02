import AppKit
import MailStore
import MessageContent
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentLibraryRow: View, Equatable {
    let item: AttachmentLibraryItem
    let accountName: String
    let accounts: [AccountRecord]
    var compact = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.accountName == rhs.accountName && lhs.accounts == rhs.accounts && lhs.compact == rhs.compact
    }

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            AttachmentFileIcon(item: item, size: Tokens.Space.s8)
                .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                .background(AttachmentPresentation.tint(item).opacity(Tokens.Opacity.wash),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(item.filename).font(.body.weight(.semibold)).lineLimit(1)
                    .truncationMode(.middle).help(item.filename)
                Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(item.subject)
                if compact {
                    HStack(spacing: Tokens.Space.s2) {
                        AttachmentSenderAvatar(sender: item.sender, accounts: accounts, size: Tokens.Space.s5)
                        Text(AttachmentPresentation.senderName(item.sender))
                            .lineLimit(1).help(item.sender)
                        Spacer(minLength: Tokens.Space.s1)
                        Text(item.date, format: .dateTime.day().month().year())
                            .fixedSize()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: Tokens.Space.s1_5) {
                    Text(AttachmentPresentation.format(item)).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                    Text("·")
                    Text(AttachmentPresentation.size(item.size)).fixedSize()
                    if item.category != .uncategorized {
                        Text("·")
                        Text(item.category.title).lineLimit(1).help(item.category.title)
                    }
                    if compact, accounts.count > 1 {
                        Text("·")
                        Text(accountName).lineLimit(1).truncationMode(.middle).help(accountName)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                HStack(spacing: Tokens.Space.s2) {
                    AttachmentSenderAvatar(sender: item.sender, accounts: accounts)
                    Text(AttachmentPresentation.senderName(item.sender))
                        .font(.callout).lineLimit(2).help(item.sender)
                }
                .frame(width: Tokens.Layout.sidebarMinWidth, alignment: .leading)
                VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                    Text(item.date, format: .dateTime.day().month().year())
                        .font(.callout)
                    Text(accountName).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(accountName)
                }
                .font(.caption)
                .frame(width: Tokens.Space.s16 * 2, alignment: .trailing)
            }
        }
        .padding(.vertical, Tokens.Space.s3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AttachmentPresentation.accessibilityLabel(item, account: accountName))
    }
}

struct AttachmentLibraryCard: View, Equatable {
    let item: AttachmentLibraryItem
    let accountName: String
    let accounts: [AccountRecord]
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.accountName == rhs.accountName && lhs.accounts == rhs.accounts && lhs.selected == rhs.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            fileTile
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(item.filename).font(.body.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle).help(item.filename)
                Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(item.subject)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: Tokens.Space.s2) {
                AttachmentSenderAvatar(sender: item.sender, accounts: accounts, size: Tokens.Space.s6)
                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                    Text(AttachmentPresentation.senderName(item.sender))
                        .font(.caption.weight(.medium)).lineLimit(1).help(item.sender)
                    Text(accountName).font(.caption).foregroundStyle(.secondary)
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
        }
        .padding(Tokens.Space.s3)
        .background(selected ? Color.accentColor.opacity(Tokens.Opacity.tint) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternSurface()
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                .strokeBorder(selected ? Color.accentColor : hovered ? hoverBorder : .clear,
                              lineWidth: selected ? Tokens.Border.focus : Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .onHover { hovered = $0 }
        .ternAnimation(value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AttachmentPresentation.accessibilityLabel(item, account: accountName))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var hoverBorder: Color {
        contrast == .increased ? .primary : Color.accentColor.opacity(Tokens.Opacity.outline)
    }

    private var fileTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .fill(AttachmentPresentation.tint(item).opacity(Tokens.Opacity.wash))
            AttachmentFileIcon(item: item, size: Tokens.Space.s16)
                .padding(.top, Tokens.Space.s2)
            VStack(alignment: .leading) {
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    Text(AttachmentPresentation.format(item))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary,
                                         Tokens.Surface.primary)
                        .font(.title3)
                        .opacity(selected || hovered || contrast == .increased ? 1 : Tokens.Opacity.outline)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if item.category != .uncategorized {
                    Text(item.category.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(1)
                        .padding(.horizontal, Tokens.Space.s2)
                        .padding(.vertical, Tokens.Space.s1)
                        .background(Tokens.Surface.primary, in: Capsule())
                        .overlay { Capsule().strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                }
            }
            .padding(Tokens.Space.s3)
        }
        .frame(height: Tokens.Space.s16 * 2)
    }
}

private struct AttachmentFileIcon: View {
    let item: AttachmentLibraryItem
    let size: CGFloat

    var body: some View {
        Image(nsImage: AttachmentPresentation.icon(item))
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
            DomainLogoAvatar(address: AttachmentPresentation.senderAddress(sender), size: size) {
                TernAvatar(name: sender, size: size)
            }
        }
    }

    private var matchingAccount: AccountRecord? {
        let address = AttachmentPresentation.senderAddress(sender).lowercased()
        return accounts.first { $0.email.lowercased() == address }
    }
}

@MainActor enum AttachmentPresentation {
    private struct FilePresentation {
        let type: UTType
        let tint: Color
        let icon: NSImage
    }
    private struct SenderPresentation {
        let name: String
        let address: String
    }
    private static var files: [String: FilePresentation] = [:]
    private static var senders: [String: SenderPresentation] = [:]

    static func fileType(_ item: AttachmentLibraryItem) -> UTType {
        file(item).type
    }

    static func icon(_ item: AttachmentLibraryItem) -> NSImage { file(item).icon }
    static func tint(_ item: AttachmentLibraryItem) -> Color { file(item).tint }

    private static func file(_ item: AttachmentLibraryItem) -> FilePresentation {
        let key = item.fileExtension.lowercased() + ":" + item.mimeType.lowercased()
        if let stored = files[key] { return stored }
        let type = UTType(filenameExtension: item.fileExtension) ?? UTType(mimeType: item.mimeType) ?? .data
        let prepared = FilePresentation(type: type, tint: tint(type), icon: NSWorkspace.shared.icon(for: type))
        // Native document icons are shared immutable AppKit assets. The small
        // catalog is bounded independently of the decoded contact-photo cache.
        if files.count >= 64 { files.removeAll(keepingCapacity: true) }
        files[key] = prepared
        return prepared
    }

    private static func tint(_ type: UTType) -> Color {
        if type.conforms(to: .pdf) { return Color(nsColor: .systemRed) }
        if type.conforms(to: .image) { return Color(nsColor: .systemPurple) }
        if type.conforms(to: .spreadsheet) { return Color(nsColor: .systemGreen) }
        if type.conforms(to: .presentation) || type.conforms(to: .archive) { return Color(nsColor: .systemOrange) }
        if type.conforms(to: .audio) { return Color(nsColor: .systemPink) }
        if type.conforms(to: .movie) || type.conforms(to: .text) { return Color(nsColor: .systemBlue) }
        return .secondary
    }

    static func senderName(_ sender: String) -> String {
        parsedSender(sender).name
    }

    static func senderAddress(_ sender: String) -> String { parsedSender(sender).address }

    private static func parsedSender(_ sender: String) -> SenderPresentation {
        if let stored = senders[sender] { return stored }
        let parsed = EmailAddress.parseList(sender).first
        let name = parsed.map { $0.name?.isEmpty == false ? $0.name ?? $0.address : $0.address } ?? sender
        let value = SenderPresentation(name: name, address: parsed?.address ?? "")
        if senders.count >= 512 { senders.removeAll(keepingCapacity: true) }
        // A malformed, enormous header must not turn this small display cache
        // into another copy of message content.
        if sender.utf8.count <= 4_096 { senders[sender] = value }
        return value
    }

    static func removeAll() {
        files.removeAll()
        senders.removeAll()
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
