import AppKit
import ImageIO
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
        let picture = try png(width: 512, height: 256)
        let prepared = try await ContactPhotoImages.prepareCachedThumbnail(picture)
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 160)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 80)
        let canceled = Task { try await ContactPhotoImages.prepareCachedThumbnail(picture) }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
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
