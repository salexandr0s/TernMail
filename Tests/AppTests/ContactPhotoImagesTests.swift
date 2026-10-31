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
