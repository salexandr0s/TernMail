import AppKit
import MailStore
import SwiftUI

/// Contact photos take precedence over website icons and stable initials.
struct ContactAvatar: View {
    let accountID: String
    let address: String
    let name: String
    let cache: MailCache
    let accounts: AccountStore?
    var size: CGFloat = Tokens.Control.avatar
    @Environment(\.addressAvatarContext) private var context

    private var color: Color {
        let hash = address.lowercased().utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
        return AccountAppearance.color(at: hash % AccountAppearance.palette.count)
    }

    var body: some View {
        AddressAvatar(accountID: accountID, address: address, name: name, size: size,
                      context: AddressAvatarContext(cache: cache, accounts: accounts,
                          profileAccountIDs: context.profileAccountIDs, identity: context.identity)) {
            Text(Self.initials(name: name, address: address))
                .font(size > Tokens.Control.avatar ? .headline : .caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(color.opacity(Tokens.Calendar.eventTint))
                .clipShape(Circle())
                .ternOutline(radius: size / 2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Initials on the tinted fallback disc, or "?" when neither the name nor the address has a word.
    static func initials(name: String, address: String) -> String {
        let letters = AvatarInitials.from(name: name, address: address)
        return letters.isEmpty ? "?" : letters
    }
}
