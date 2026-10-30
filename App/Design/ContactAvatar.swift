import AppKit
import MailStore
import SwiftUI

/// A photo is optional. Initials and color remain stable when Contacts or its network is unavailable.
struct ContactAvatar: View {
    let accountID: String
    let address: String
    let name: String
    let cache: MailCache
    let accounts: AccountStore?
    var size: CGFloat = Tokens.Control.avatar
    @State private var image: NSImage?

    private var color: Color {
        let hash = address.lowercased().utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
        return AccountAppearance.color(at: hash % AccountAppearance.palette.count)
    }

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Text(Self.initials(name: name, address: address))
                    .font(size > Tokens.Control.avatar ? .headline : .caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.opacity(Tokens.Calendar.eventTint))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(color, lineWidth: Tokens.Border.hairline))
        .accessibilityHidden(true)
        .task(id: accountID + ":" + address.lowercased()) { await observe() }
    }

    private func observe() async {
        image = nil
        guard let accounts else { return }
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
                guard enabled else { continue }
                photos = Task {
                    do {
                        for try await record in cache.observeContactPhoto(accountID: accountID, address: address) {
                            guard !Task.isCancelled else { return }
                            guard let record else { image = nil; continue }
                            let loaded = await ContactPhotoImages.image(for: record, address: address, cache: cache, accounts: accounts)
                            guard !Task.isCancelled else { return }
                            image = loaded
                        }
                    } catch { if !Task.isCancelled { image = nil } }
                }
            }
        } catch { if !Task.isCancelled { image = nil } }
    }

    static func initials(name: String, address: String) -> String {
        let value = name.isEmpty ? address : name
        let words = value.prefix { $0 != "@" }.split { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" }
        guard let first = words.first else { return "?" }
        if words.count > 1, let last = words.last { return (String(first.prefix(1)) + String(last.prefix(1))).uppercased() }
        return String(first.prefix(2)).uppercased()
    }
}
