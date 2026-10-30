import MailStore
import SwiftUI

/// Uses a rendered image so the native menu and its selected value share the avatar.
struct SenderAccountLabel: View {
    let account: AccountRecord
    var address: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private static let avatarSize = Tokens.Space.s5

    var body: some View {
        Label {
            Text(address ?? account.email)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(nsImage: avatarImage)
                .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
    }

    private var avatarImage: NSImage {
        let renderer = ImageRenderer(content: avatar
            .environment(\.colorScheme, colorScheme))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: Self.avatarSize, height: Self.avatarSize))
    }

    @ViewBuilder private var avatar: some View {
        if let image = AccountProfileImages.shared.image(for: account.id) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(contrast == .increased ? Color.primary : Tokens.Surface.border,
                                          lineWidth: Tokens.Border.hairline)
                }
        } else {
            TernAvatar(name: avatarName, size: Self.avatarSize)
        }
    }

    private var avatarName: String {
        let name = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? account.email : name
    }

#if DEBUG
    /// A local illustration exercises the photo path without a Google account.
    static var auditImage: NSImage {
        let renderer = ImageRenderer(content:
            Image(systemName: "person.crop.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .indigo)
                .font(.system(size: Tokens.Control.avatarLarge))
                .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                .background(.indigo.gradient)
        )
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: Tokens.Space.s16, height: Tokens.Space.s16))
    }
#endif
}
