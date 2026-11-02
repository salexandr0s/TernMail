import AppKit
import ImageIO
import MailStore
import Testing
@testable import Tern

@MainActor @Suite struct ContactPhotoImagesTests {
    @Test func photoRequestsHaveNoCredentialsAndRejectUntrustedTargetsBeforeFetching() async throws {
        let picture = try png(width: 10, height: 10)
        let transport = PhotoRequests(data: picture)
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/person"))
        let data = try await ContactPhotoImages.loadThumbnail(url: url, fetch: { try await transport.fetch($0) })
        #expect(NSImage(data: data) != nil)
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.url?.query?.contains("sz=160") == true)
        let attacker = try #require(URL(string: "https://googleusercontent.com.attacker.invalid/person"))
        await #expect(throws: ContactPhotoImages.PhotoError.self) {
            try await ContactPhotoImages.loadThumbnail(url: attacker, fetch: { try await transport.fetch($0) })
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func redirectsFormatsBytesAndPixelBombsCannotBecomeCachedPhotos() async throws {
        let good = try png(width: 10, height: 10)
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/person"))
        let redirected = PhotoRequests(data: good, finalURL: URL(string: "https://attacker.invalid/person"))
        await #expect(throws: ContactPhotoImages.PhotoError.self) {
            try await ContactPhotoImages.loadThumbnail(url: url, fetch: { try await redirected.fetch($0) })
        }
        let svg = PhotoRequests(data: Data("<svg/>".utf8), mimeType: "image/svg+xml")
        await #expect(throws: ContactPhotoImages.PhotoError.self) {
            try await ContactPhotoImages.loadThumbnail(url: url, fetch: { try await svg.fetch($0) })
        }
        let excessive = PhotoRequests(data: Data(repeating: 0, count: ContactPhotoImages.maximumBytes + 1))
        await #expect(throws: ContactPhotoImages.PhotoError.self) {
            try await ContactPhotoImages.loadThumbnail(url: url, fetch: { try await excessive.fetch($0) })
        }
        let tooWide = try png(width: ContactPhotoImages.maximumDimension + 1, height: 1)
        #expect(throws: ContactPhotoImages.PhotoError.self) { try ContactPhotoImages.thumbnail(tooWide) }
        let tooManyPixels = try png(width: 2049, height: 2049)
        #expect(throws: ContactPhotoImages.PhotoError.self) { try ContactPhotoImages.thumbnail(tooManyPixels) }
    }

    @Test func cachedPreparationBoundsImagesAndPropagatesCancellation() async throws {
        let cache = ContactThumbnailCache(monitorsPressure: false)
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/person"))
        let record = ContactPhotoRecord(accountID: "a", source: .connection, resourceName: "people/1", url: url)
        let picture = try png(width: 512, height: 256)
        let prepared = try await cache.image(for: ContactPhotoCacheKey(record, contextID: "bounds"), data: picture)
        #expect(prepared.size.width == 160)
        #expect(prepared.size.height == 80)
        let canceled = Task {
            try await cache.image(for: ContactPhotoCacheKey(record, contextID: "cancelled"), data: picture)
        }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(cache.decodeCount == 1, "An already cancelled caller must not start another decode")
        #expect(cache.pendingCount == 0)
    }

    @Test(arguments: PhotoDecodeInvalidation.allCases)
    func abandonedDecodesReleasePendingPixelsAndRejectLateResults(_ invalidation: PhotoDecodeInvalidation) async throws {
        let data = try png(width: 20, height: 20)
        let gate = PendingContactDecode(result: try prepared(data))
        let cache = ContactThumbnailCache(monitorsPressure: false, decode: { await gate.decode($0) })
        let key = try photoKey()
        let request = Task { try await cache.image(for: key, data: data) }
        await gate.waitUntilStarted()
        #expect(cache.pendingCount == 1)
        switch invalidation {
        case .caller: request.cancel()
        case .account: cache.remove(accountID: key.accountID)
        case .pressure: cache.removeAll()
        }
        #expect(await waitForWaiters(0, key: key, cache: cache))
        await gate.finish()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(cache.pendingCount == 0)
        #expect(cache.image(for: key) == nil)
        #expect(cache.cost == 0)
    }

    @Test(arguments: [0, 1, 32 * 1_024 * 1_024])
    func sharedDecodeSurvivesOneCancellationEvenWhenPixelsCannotBeCached(_ capacity: Int) async throws {
        let data = try png(width: 20, height: 20)
        let gate = PendingContactDecode(result: try prepared(data))
        let cache = ContactThumbnailCache(capacity: capacity, monitorsPressure: false, decode: { await gate.decode($0) })
        let key = try photoKey()
        let canceled = Task { try await cache.image(for: key, data: data) }
        await gate.waitUntilStarted()
        let first = Task { try await cache.image(for: key, data: data) }
        let second = Task { try await cache.image(for: key, data: data) }
        #expect(await waitForWaiters(3, key: key, cache: cache))
        canceled.cancel()
        #expect(await waitForWaiters(2, key: key, cache: cache))
        await gate.finish()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        let images = try await (first.value, second.value)
        #expect(images.0.size == NSSize(width: 20, height: 20))
        #expect(images.1.size == images.0.size)
        #expect(cache.decodeCount == 1)
        #expect(cache.pendingCount == 0)
        #expect(cache.cost <= capacity)
    }

    @Test func decodedPhotosReusePixelsAndSeparateLifetimesAndVersions() async throws {
        let cache = ContactThumbnailCache(monitorsPressure: false)
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/person"))
        var record = ContactPhotoRecord(accountID: "a", source: .connection, resourceName: "people/1",
            url: url, version: "v1", fetchedAt: .now)
        let firstKey = ContactPhotoCacheKey(record, contextID: "lifetime-1")
        let data = try png(width: 20, height: 20)
        async let first = cache.image(for: firstKey, data: data)
        async let joined = cache.image(for: firstKey, data: data)
        let images = try await (first, joined)
        #expect(images.0 === images.1)
        #expect(cache.decodeCount == 1)
        #expect(try await cache.image(for: firstKey, data: data) === images.0)
        #expect(cache.decodeCount == 1)

        let newLifetime = ContactPhotoCacheKey(record, contextID: "lifetime-2")
        #expect(cache.image(for: newLifetime) == nil)
        record.version = "v2"
        let newVersion = ContactPhotoCacheKey(record, contextID: "lifetime-1")
        #expect(cache.image(for: newVersion) == nil)
        record.accountID = "b"
        let otherAccount = ContactPhotoCacheKey(record, contextID: "lifetime-1")
        _ = try await cache.image(for: otherAccount, data: data)
        cache.remove(accountID: "a")
        #expect(cache.image(for: firstKey) == nil)
        #expect(cache.image(for: otherAccount) != nil)
        cache.removeAll()
        #expect(cache.cost == 0)
    }

    @Test func decodedPhotoBudgetEvictsOldPixels() async throws {
        let cache = ContactThumbnailCache(capacity: 160 * 160 * 4, monitorsPressure: false)
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/person"))
        let data = try png(width: 160, height: 160)
        let first = ContactPhotoCacheKey(ContactPhotoRecord(accountID: "a", source: .connection,
            resourceName: "first", url: url), contextID: "test")
        let second = ContactPhotoCacheKey(ContactPhotoRecord(accountID: "a", source: .connection,
            resourceName: "second", url: url), contextID: "test")
        _ = try await cache.image(for: first, data: data)
        _ = try await cache.image(for: second, data: data)
        #expect(cache.cost <= cache.capacity)
        #expect(cache.image(for: first) == nil)
        #expect(cache.image(for: second) != nil)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func photoKey() throws -> ContactPhotoCacheKey {
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/person"))
        return ContactPhotoCacheKey(ContactPhotoRecord(accountID: "a", source: .connection,
            resourceName: "people/1", url: url), contextID: "pending-test")
    }

    private func prepared(_ data: Data) throws -> PreparedContactThumbnail {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return PreparedContactThumbnail(pixels: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func waitForWaiters(_ count: Int, key: ContactPhotoCacheKey, cache: ContactThumbnailCache) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while cache.waiterCount(for: key) != count, ContinuousClock.now < deadline { await Task.yield() }
        return cache.waiterCount(for: key) == count
    }
}

enum PhotoDecodeInvalidation: CaseIterable { case caller, account, pressure }

/// Keeps the decode pending until every caller is installed; ignores cancellation
/// so the cache must reject a late pixel result after its final waiter leaves.
private actor PendingContactDecode {
    private let result: PreparedContactThumbnail
    private var continuation: CheckedContinuation<PreparedContactThumbnail, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: PreparedContactThumbnail) { self.result = result }

    func decode(_ data: Data) async -> PreparedContactThumbnail {
        await withCheckedContinuation {
            continuation = $0
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor PhotoRequests {
    let data: Data
    let finalURL: URL?
    let mimeType: String
    private(set) var requests: [URLRequest] = []
    init(data: Data, finalURL: URL? = nil, mimeType: String = "image/png") { self.data = data; self.finalURL = finalURL; self.mimeType = mimeType }
    func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(finalURL ?? request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mimeType]))
        return (data, response)
    }
}
