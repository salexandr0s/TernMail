import AppKit
import ImageIO
import SwiftUI

/// Website icons supplement missing photos without changing images inside mail.
struct DomainLogoAvatar<Placeholder: View>: View {
    let address: String
    let size: CGFloat
    let allowsLookup: Bool
    private let placeholder: Placeholder
    private let load: AddressAvatarModel.LogoLoader
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = DomainLogoPreferences.defaultEnabled
    @State private var image: NSImage?
    @State private var loadedAddress: String?

    init(address: String, size: CGFloat = Tokens.Control.avatar, allowsLookup: Bool = true,
         load: @escaping AddressAvatarModel.LogoLoader = { await DomainLogoImages.shared.data(for: $0) },
         @ViewBuilder placeholder: () -> Placeholder) {
        self.address = address
        self.size = size
        self.allowsLookup = allowsLookup
        self.load = load
        self.placeholder = placeholder()
    }

    private var request: Request {
        Request(address: address.lowercased(), enabled: showsLogos && allowsLookup)
    }

    var body: some View {
        Group {
            if request.enabled, let image = loadedAddress == request.address ? image : DomainLogoThumbnailCache.shared.image(for: request.address) {
                AvatarImage(image: image, size: size)
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: request) {
            let current = request
            guard current.enabled else { image = nil; loadedAddress = nil; return }
            if loadedAddress != current.address {
                image = DomainLogoThumbnailCache.shared.image(for: current.address)
                loadedAddress = current.address
            }
            let data = await load(current.address)
            guard !Task.isCancelled else { return }
            let prepared = if let data { await DomainLogoThumbnailCache.shared.image(for: current.address, data: data) } else { nil as NSImage? }
            guard !Task.isCancelled else { return }
            image = prepared
            loadedAddress = current.address
        }
    }

    private struct Request: Hashable {
        let address: String
        let enabled: Bool
    }
}

/// Public logos have a separate pixel budget from account-scoped contact photos.
@MainActor final class DomainLogoThumbnailCache {
    static let shared = DomainLogoThumbnailCache()
    private let capacity: Int
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var pending: [Data: Pending] = [:]
    private var sequence = 0
    private var generation = UUID()
    private(set) var cost = 0
    private(set) var decodeCount = 0

    private struct Entry {
        let data: Data
        let image: NSImage
        let expires: Date
        let cost: Int
        var used: Int
    }
    private struct Pending {
        let id: UUID
        let task: Task<PreparedDomainLogoThumbnail?, Never>
    }

    init(capacity: Int = 8 * 1_024 * 1_024, now: @escaping () -> Date = Date.init) {
        self.capacity = max(0, capacity)
        self.now = now
    }

    func image(for address: String) -> NSImage? {
        guard !entries.isEmpty else { return nil }
        guard let domain = DomainLogoImages.domain(for: address), var entry = entries[domain] else { return nil }
        guard entry.expires > now() else { remove(domain); return nil }
        sequence += 1; entry.used = sequence; entries[domain] = entry
        return entry.image
    }

    func image(for address: String, data: Data) async -> NSImage? {
        guard let domain = DomainLogoImages.domain(for: address) else { return nil }
        if entries[domain]?.data == data, let cached = image(for: address) { return cached }
        let token = generation
        let work: Pending
        if let existing = pending[data] { work = existing }
        else {
            let task = Task { await DomainLogoThumbnailDecoder.shared.decode(data) }
            work = Pending(id: UUID(), task: task)
            pending[data] = work
            decodeCount += 1
        }
        defer { if pending[data]?.id == work.id { pending[data] = nil } }
        let prepared = await work.task.value
        guard generation == token else { return nil }
        // A joined caller may already have installed the shared pixels.
        if entries[domain]?.data == data, let cached = image(for: address) { return cached }
        guard let prepared else { remove(domain); return nil }
        let image = NSImage(cgImage: prepared.pixels,
            size: NSSize(width: prepared.pixels.width, height: prepared.pixels.height))
        remove(domain)
        let bytes = prepared.cost + data.count
        if bytes <= capacity {
            while cost + bytes > capacity || entries.count >= 128,
                  let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { remove(oldest) }
            sequence += 1
            entries[domain] = Entry(data: data, image: image, expires: now().addingTimeInterval(7 * 86400), cost: bytes, used: sequence)
            cost += bytes
        }
        return image
    }

    func removeAll() {
        generation = UUID()
        entries.removeAll(); cost = 0
        for work in pending.values { work.task.cancel() }
        pending.removeAll()
    }

    private func remove(_ domain: String) {
        if let entry = entries.removeValue(forKey: domain) { cost -= entry.cost }
    }
}

/// CGImage pixels are immutable; AppKit wrapping stays on the main actor.
private struct PreparedDomainLogoThumbnail: @unchecked Sendable {
    let pixels: CGImage
    var cost: Int { pixels.bytesPerRow * pixels.height }
}

private actor DomainLogoThumbnailDecoder {
    static let shared = DomainLogoThumbnailDecoder()

    func decode(_ data: Data) -> PreparedDomainLogoThumbnail? {
        guard !Task.isCancelled, let clean = try? DomainLogoImages.thumbnail(data),
              let source = CGImageSourceCreateWithData(clean as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), !Task.isCancelled else { return nil }
        return PreparedDomainLogoThumbnail(pixels: pixels)
    }
}
