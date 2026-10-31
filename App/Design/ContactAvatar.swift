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
    @State private var image: NSImage?
    @State private var resolvedIdentity: String?

    private var identity: String { accountID + ":" + address.lowercased() }

    private var color: Color {
        let hash = address.lowercased().utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
        return AccountAppearance.color(at: hash % AccountAppearance.palette.count)
    }

    var body: some View {
        Group {
            if resolvedIdentity == identity, let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                DomainLogoAvatar(address: address, size: size, allowsLookup: resolvedIdentity == identity) {
                    Text(Self.initials(name: name, address: address))
                        .font(size > Tokens.Control.avatar ? .headline : .caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(color.opacity(Tokens.Calendar.eventTint))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(color, lineWidth: Tokens.Border.hairline))
        .accessibilityHidden(true)
        .task(id: identity) { await observe() }
    }

    private func observe() async {
        image = nil
        resolvedIdentity = nil
        guard let accounts else { resolvedIdentity = identity; return }
        var photos: Task<Void, Never>?
        var previousAccess: Bool?
        defer { photos?.cancel() }
        do {
            for try await enabled in accounts.observeContactAccess(accountID: accountID) {
                guard !Task.isCancelled else { return }
                if previousAccess == enabled { continue }
                previousAccess = enabled
                photos?.cancel()
                image = nil
                resolvedIdentity = nil
                guard enabled else { resolvedIdentity = identity; continue }
                photos = Task {
                    do {
                        for try await record in cache.observeContactPhoto(accountID: accountID, address: address) {
                            guard !Task.isCancelled else { return }
                            guard let record else { image = nil; resolvedIdentity = identity; continue }
                            let loaded = await ContactPhotoImages.image(for: record, address: address, cache: cache, accounts: accounts)
                            guard !Task.isCancelled else { return }
                            image = loaded
                            resolvedIdentity = identity
                        }
                    } catch { if !Task.isCancelled { image = nil; resolvedIdentity = identity } }
                }
            }
        } catch { if !Task.isCancelled { image = nil; resolvedIdentity = identity } }
    }

    static func initials(name: String, address: String) -> String {
        let value = name.isEmpty ? address : name
        let words = value.prefix { $0 != "@" }.split { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" }
        guard let first = words.first else { return "?" }
        if words.count > 1, let last = words.last { return (String(first.prefix(1)) + String(last.prefix(1))).uppercased() }
        return String(first.prefix(2)).uppercased()
    }
}
