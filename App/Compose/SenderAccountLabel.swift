import MailStore
import Observation
import SwiftUI

/// Uses a rendered image so the native menu and its selected value share the avatar.
struct SenderAccountLabel: View {
    let account: AccountRecord
    var address: String?
    var avatarModel: AddressAvatarModel?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = true

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
        if let image = displayedImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: displaysLogo ? .fit : .fill)
                .padding(displaysLogo ? Tokens.Space.s0_5 : 0)
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

    private var displayedImage: NSImage? {
        if let photo = AccountProfileImages.shared.image(for: account.id) { return photo }
        guard avatarModel?.isLogo != true || showsLogos else { return nil }
        return avatarModel?.image
    }

    private var displaysLogo: Bool {
        AccountProfileImages.shared.image(for: account.id) == nil && avatarModel?.isLogo == true
    }

    private var avatarName: String {
        let name = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? account.email : name
    }

#if DEBUG || TERN_PERFORMANCE
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

/// Compose owns loaders so native menu images are ready before menu rendering.
@MainActor @Observable
final class SenderAvatarModels {
    private(set) var models: [String: AddressAvatarModel] = [:]

    func configure(senders: [ComposeSender], context: AddressAvatarContext, showsLogos: Bool) {
        let ids = Set(senders.map(\.id))
        for id in Array(models.keys) where !ids.contains(id) { models.removeValue(forKey: id)?.stop() }
        for sender in senders {
            let model = models[sender.id] ?? AddressAvatarModel()
            models[sender.id] = model
            model.configure(address: sender.address, accountID: sender.account.id, context: context,
                            showsLogos: showsLogos, preferredAccountID: sender.account.id)
        }
    }

    func stop() {
        models.values.forEach { $0.stop() }
        models.removeAll()
    }
}
