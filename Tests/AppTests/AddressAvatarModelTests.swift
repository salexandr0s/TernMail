import AppKit
import GmailAPI
import MailStore
import Observation
import SwiftUI
import Testing
@testable import Tern

@MainActor @Suite struct AddressAvatarModelTests {
    @Test func ownPhotosHavePriorityAndLatePhotosReplaceLogosWithoutLeakingToGuests() async throws {
        let profiles = AvatarProfiles()
        let photo = NSImage(size: NSSize(width: 24, height: 24))
        profiles.images["owner"] = photo
        let requests = AvatarLogoRequests(data: try png(width: 32))
        let context = AddressAvatarContext(profileAccountIDs: ["me@brand.com": "owner"], identity: "accounts")
        let model = AddressAvatarModel(logoLoader: { await requests.load($0) }, profilePhoto: { profiles.images[$0] })
        defer { model.stop() }
        model.configure(address: "me@brand.com", accountID: "owner", context: context, showsLogos: true)
        #expect(model.image === photo)
        #expect(await requests.addresses.isEmpty)

        model.configure(address: "guest@brand.com", accountID: "owner", context: context, showsLogos: true)
        try await wait { model.isLogo }
        #expect(model.image !== photo)
        #expect(await requests.addresses == ["guest@brand.com"])

        profiles.images["owner"] = nil
        model.configure(address: "me@brand.com", accountID: "owner", context: context, showsLogos: true)
        try await wait { model.isLogo }
        profiles.images["owner"] = photo
        try await wait { model.image === photo && !model.isLogo }
        profiles.images["owner"] = nil
        try await wait { model.isLogo }
        model.stop()
        profiles.images["owner"] = photo
        await Task.yield()
        #expect(model.image == nil)
    }

    @Test func contactPhotosStayAccountScopedAndRevocationRevealsTheLogo() async throws {
        let cache = try MailCache.inMemory()
        let accounts = try AccountStore.inMemory()
        for id in ["a", "b"] {
            var account = AccountRecord(id: id, email: "\(id)@brand.com", displayName: nil, grantedScopes: [], addedAt: .now)
            account.enabledFeatures = ["contacts"]
            try await accounts.save(account)
        }
        let people = try JSONDecoder().decode([Person].self, from: Data(#"[{"resourceName":"people/guest","emailAddresses":[{"value":"guest@brand.com"}],"photos":[{"url":"https://lh3.googleusercontent.com/guest","default":false}]}]"#.utf8))
        try await cache.write { try $0.applyEnrichedContactSync(people, source: .connection, syncToken: nil,
            fields: PeopleClient.fields, isFullSync: true, now: .now, accountID: "a") }
        let record = try #require(try await cache.contactPhoto(accountID: "a", address: "guest@brand.com"))
        #expect(try await cache.storeContactPhoto(png(width: 16), for: record))
        let requests = AvatarLogoRequests(data: try png(width: 32))
        let context = AddressAvatarContext(cache: cache, accounts: accounts, identity: "contacts")
        let model = AddressAvatarModel(logoLoader: { await requests.load($0) })
        defer { model.stop() }
        model.configure(address: "guest@brand.com", accountID: "a", context: context, showsLogos: true)
        try await wait { model.image != nil }
        #expect(!model.isLogo)
        #expect(await requests.addresses.isEmpty)
        model.configure(address: "guest@brand.com", accountID: "b", context: context, showsLogos: true)
        try await wait { model.isLogo }
        model.configure(address: "guest@brand.com", accountID: "a", context: context, showsLogos: true)
        try await wait { model.image != nil && !model.isLogo }
        try await accounts.updateAccount(id: "a") { $0.enabledFeatures = [] }
        try await wait { model.isLogo }
    }

    @Test func disablingAndChangingAddressRejectLateLogoResults() async throws {
        let loader = PendingAvatarLogos()
        let model = AddressAvatarModel(logoLoader: { await loader.load($0) })
        defer { model.stop() }
        model.configure(address: "old@brand.com", accountID: nil, context: .empty, showsLogos: true)
        await loader.waitFor(1)
        model.configure(address: "old@brand.com", accountID: nil, context: .empty, showsLogos: false)
        await loader.finish(1, data: try png(width: 16))
        await Task.yield()
        #expect(model.image == nil)
        model.configure(address: "old@brand.com", accountID: nil, context: .empty, showsLogos: true)
        await loader.waitFor(2)
        model.configure(address: "new@bank.com", accountID: nil, context: .empty, showsLogos: true)
        await loader.waitFor(3)
        await loader.finish(3, data: try png(width: 32))
        try await wait { model.isLogo }
        let current = model.image
        await loader.finish(2, data: try png(width: 16))
        await Task.yield()
        #expect(model.image === current)
    }

    @Test func partialAndMalformedAddressesNeverStartLogoRequests() async throws {
        let requests = AvatarLogoRequests(data: try png(width: 16))
        let model = AddressAvatarModel(logoLoader: { await requests.load($0) })
        defer { model.stop() }
        for value in ["", "Bank", "person@", "Bank <person@bank.com>", "person@bank.com@other.com"] {
            model.configure(address: value, accountID: nil, context: .empty, showsLogos: true)
            #expect(model.image == nil)
        }
        #expect(await requests.addresses.isEmpty)
    }

    @Test func nativeDisappearanceKeepsLoadedPixelsAndDoesNotRestartLookup() async throws {
        let requests = AvatarLogoRequests(data: try png(width: 32))
        let model = AddressAvatarModel(logoLoader: { await requests.load($0) })
        let mounting = AvatarMounting()
        let suite = "Tern.AvatarLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: DomainLogoImages.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: AvatarLifecycleHost(model: model, mounting: mounting, defaults: defaults))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 80, height: 80))
        window.orderFront(nil)
        defer { model.stop(); window.close(); window.contentViewController = nil }
        try await wait { model.isLogo && mounting.appeared == 1 }
        let image = try #require(model.image)

        mounting.visible = false
        try await wait { mounting.disappeared == 1 }
        #expect(model.image === image)
        mounting.visible = true
        try await wait { mounting.appeared == 2 }
        #expect(model.image === image)
        #expect(await requests.addresses == ["guest@brand.com"])
    }

    @Test func firstRenderUsesKnownProfilePhotoAndRejectsOtherAddresses() throws {
        let photo = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
        let context = AddressAvatarContext(profileAccountIDs: ["me@brand.com": "owner"], identity: "preview")
        let model = AddressAvatarModel(profilePhoto: { $0 == "owner" ? photo : nil })
        defer { model.stop() }
        for (address, expectedRed) in [("me@brand.com", true), ("guest@brand.com", false)] {
            let renderer = ImageRenderer(content: AddressAvatar(address: address, size: 24, context: context, model: model) {
                Color.blue.frame(width: 24, height: 24)
            })
            let image = try #require(renderer.nsImage)
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(expectedRed ? color.redComponent > 0.9 : color.blueComponent > 0.9)
        }
    }

    @Test func releasedModelCancelsItsAccessObservation() async throws {
        let cache = try MailCache.inMemory()
        let accounts = try AccountStore.inMemory()
        let owner = AccountRecord(id: "avatar-lifetime", email: "me@brand.com", displayName: nil, grantedScopes: [], addedAt: .now)
        try await accounts.save(owner)
        let data = try png(width: 32)
        var model: AddressAvatarModel? = AddressAvatarModel(logoLoader: { _ in data })
        model?.configure(address: "guest@brand.com", accountID: owner.id,
            context: AddressAvatarContext(cache: cache, accounts: accounts), showsLogos: true)
        try await wait { model?.isLogo == true }
        weak var released = model
        model = nil
        try await wait { released == nil }
    }

    @Test func decodedLogosSharePixelsAndRespectBudgetExpiryAndReset() async throws {
        let data = try png(width: 32)
        var date = Date.now
        let cache = DomainLogoThumbnailCache(capacity: 32 * 32 * 4 + data.count, now: { date })
        let first = try #require(await cache.image(for: "first@brand.com", data: data))
        #expect(cache.image(for: "second@brand.com") === first)
        #expect(await cache.image(for: "second@brand.com", data: data) === first)
        #expect(cache.decodeCount == 1)
        #expect(cache.image(for: "person@other.com") == nil)
        #expect(await cache.image(for: "person@other.com", data: data) != nil)
        #expect(cache.image(for: "first@brand.com") == nil)
        date = date.addingTimeInterval(7 * 86400 + 1)
        #expect(cache.image(for: "person@other.com") == nil)
        #expect(cache.cost == 0)
        #expect(await cache.image(for: "first@brand.com", data: data) != nil)
        cache.removeAll()
        #expect(cache.image(for: "first@brand.com") == nil)
        #expect(cache.cost == 0)
    }

    @Test func firstLogoRenderReusesWarmPixelsAndHonorsLookupPreference() async throws {
        let address = "sender@\(UUID().uuidString.lowercased()).com"
        let photo = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
        let photoData = try #require(photo.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: photoData))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(await DomainLogoThumbnailCache.shared.image(for: address, data: data) != nil)
        let suite = "Tern.AvatarWarmLogoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: DomainLogoImages.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        for enabled in [true, false] {
            let renderer = ImageRenderer(content: DomainLogoAvatar(address: address, size: 24, allowsLookup: enabled, load: { _ in nil }) {
                Color.blue.frame(width: 24, height: 24)
            }.defaultAppStorage(defaults))
            let rendered = try #require(renderer.nsImage)
            let renderedData = try #require(rendered.tiffRepresentation)
            let pixels = try #require(NSBitmapImageRep(data: renderedData))
            let center = try #require(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(enabled ? center.redComponent > 0.9 : center.blueComponent > 0.9)
        }
    }

    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !ready() {
            guard ContinuousClock.now < deadline else { Issue.record("Avatar did not reach its expected state"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func png(width: Int) throws -> Data {
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        return try #require(pixels.representation(using: .png, properties: [:]))
    }
}

@MainActor @Observable private final class AvatarMounting {
    var visible = true
    var appeared = 0
    var disappeared = 0
}

private struct AvatarLifecycleHost: View {
    let model: AddressAvatarModel
    let mounting: AvatarMounting
    let defaults: UserDefaults

    var body: some View {
        Group {
            if mounting.visible {
                AddressAvatar(address: "guest@brand.com", context: .empty, model: model) { Color.blue }
                    .onAppear { mounting.appeared += 1 }
                    .onDisappear { mounting.disappeared += 1 }
            }
        }
        .defaultAppStorage(defaults)
    }
}

@MainActor @Observable private final class AvatarProfiles { var images: [String: NSImage] = [:] }

private actor AvatarLogoRequests {
    let data: Data
    private(set) var addresses: [String] = []
    init(data: Data) { self.data = data }
    func load(_ address: String) -> Data? { addresses.append(address); return data }
}

/// Ignores cancellation to exercise late-result guards.
private actor PendingAvatarLogos {
    private var count = 0
    private var pending: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func load(_ address: String) async -> Data? {
        await withCheckedContinuation { continuation in
            count += 1; pending[count] = continuation
            waiters.filter { count >= $0.0 }.forEach { $0.1.resume() }
            waiters.removeAll { count >= $0.0 }
        }
    }
    func waitFor(_ needed: Int) async {
        if count < needed { await withCheckedContinuation { waiters.append((needed, $0)) } }
    }
    func finish(_ index: Int, data: Data) { pending.removeValue(forKey: index)?.resume(returning: data) }
}
