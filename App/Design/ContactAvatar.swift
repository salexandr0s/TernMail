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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(color.opacity(Tokens.Calendar.eventTint))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(color, lineWidth: Tokens.Border.hairline))
        .accessibilityHidden(true)
    }

    static func initials(name: String, address: String) -> String {
        let value = name.isEmpty ? address : name
        let words = value.prefix { $0 != "@" }.split { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" }
        guard let first = words.first else { return "?" }
        if words.count > 1, let last = words.last { return (String(first.prefix(1)) + String(last.prefix(1))).uppercased() }
        return String(first.prefix(2)).uppercased()
    }
}
