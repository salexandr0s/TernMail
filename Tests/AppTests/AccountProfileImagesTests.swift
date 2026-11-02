import AppKit
import GmailAPI
import Testing
@testable import Tern

@MainActor
@Suite struct AccountProfileImagesTests {
    @Test func userinfoChecksIdentityAndTheImageRequestHasNoToken() async throws {
        let profile = ProfileTransport(data: Data(#"{"sub":"a","picture":"https://images.example.invalid/photo.png"}"#.utf8))
        let picture = ProfileTransport(data: try photoData())
        let photo = try await AccountProfileImages.loadGooglePhoto(
            accountID: "a", tokens: ProfileTokens(), profileTransport: profile, pictureTransport: picture
        )
        #expect(photo != nil)
        let profileRequest = try #require(await profile.requests.first)
        #expect(profileRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(profileRequest.cachePolicy == .reloadIgnoringLocalCacheData)
        let imageRequest = try #require(await picture.requests.first)
        #expect(imageRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(imageRequest.url?.host == "images.example.invalid")

        let wrongProfile = ProfileTransport(data: Data(#"{"sub":"b","picture":"https://images.example.invalid/photo.png"}"#.utf8))
        do {
            _ = try await AccountProfileImages.loadGooglePhoto(
                accountID: "a", tokens: ProfileTokens(), profileTransport: wrongProfile, pictureTransport: picture
            )
            Issue.record("A different Google account's photo was accepted")
        } catch AccountProfileImages.LoadError.identityMismatch {}
        #expect(await picture.requests.count == 1)
    }

    @Test func insecurePictureURLsAreRejectedBeforeFetching() async throws {
        let profile = ProfileTransport(data: Data(#"{"sub":"a","picture":"http://images.example.invalid/photo.png"}"#.utf8))
        let picture = ProfileTransport(data: Data())
        do {
            _ = try await AccountProfileImages.loadGooglePhoto(
                accountID: "a", tokens: ProfileTokens(), profileTransport: profile, pictureTransport: picture
            )
            Issue.record("An insecure picture URL was accepted")
        } catch AccountProfileImages.LoadError.invalidPictureURL {}
        #expect(await picture.requests.isEmpty)
    }

    @Test func failuresKeepTheLastPhotoAndAccountsStaySeparate() async throws {
        let loader = ProfileLoader(result: .success(.init(data: try photoData())))
        let images = AccountProfileImages { _, _ in try await loader.load() }
        await images.refresh(accountID: "a", tokens: ProfileTokens()).value
        let original = try #require(images.image(for: "a"))
        #expect(images.image(for: "b") == nil)

        await loader.set(.failure(URLError(.notConnectedToInternet)))
        await images.refresh(accountID: "a", tokens: ProfileTokens()).value
        await images.refresh(accountID: "b", tokens: ProfileTokens()).value
        #expect(images.image(for: "a") === original)
        #expect(images.image(for: "b") == nil)

        await loader.set(.success(.init(data: Data("not an image".utf8))))
        await images.refresh(accountID: "a", tokens: ProfileTokens()).value
        #expect(images.image(for: "a") === original)
        await loader.set(.success(nil))
        await images.refresh(accountID: "a", tokens: ProfileTokens()).value
        #expect(images.image(for: "a") == nil)
    }

    @Test func signOutAndReplacementRejectLateResponses() async throws {
        let loader = PendingProfileLoader()
        let images = AccountProfileImages { _, _ in await loader.load() }
        let photo = AccountProfileImages.Photo(data: try photoData())
        let first = images.refresh(accountID: "a", tokens: ProfileTokens())
        await loader.waitForRequests(1)
        images.remove(accountID: "a")
        await loader.finish(1, photo: photo)
        await first.value
        #expect(first.isCancelled)
        #expect(images.image(for: "a") == nil)

        let old = images.refresh(accountID: "a", tokens: ProfileTokens())
        await loader.waitForRequests(2)
        let replacement = images.refresh(accountID: "a", tokens: ProfileTokens())
        await loader.waitForRequests(3)
        await loader.finish(3, photo: photo)
        await replacement.value
        let current = try #require(images.image(for: "a"))
        await loader.finish(2, photo: photo)
        await old.value
        #expect(images.image(for: "a") === current)
    }

    @Test func backgroundPreparationKeepsImageBoundsAndRejectsOversizedData() async throws {
        let loader = ProfileLoader(result: .success(.init(data: try photoData(width: 512, height: 256))))
        let images = AccountProfileImages { _, _ in try await loader.load() }
        await images.refresh(accountID: "a", tokens: ProfileTokens()).value
        let original = try #require(images.image(for: "a"))
        #expect(original.size == NSSize(width: 128, height: 64))
        await loader.set(.success(.init(data: Data(repeating: 0, count: 5 * 1_024 * 1_024 + 1))))
        await images.refresh(accountID: "a", tokens: ProfileTokens()).value
        #expect(images.image(for: "a") === original)
    }

    @Test func cancellationDuringDecodeCannotRestorePhotoOrDiscardReplacementTask() async throws {
        let photo = AccountProfileImages.Photo(data: try photoData())
        let bitmap = try #require(NSBitmapImageRep(data: photo.data))
        let decoder = PendingProfileDecode(result: PreparedAccountProfileImage(pixels: try #require(bitmap.cgImage)))
        let images = AccountProfileImages(decode: { await decoder.decode($0) }, load: { _, _ in photo })
        let first = images.refresh(accountID: "a", tokens: ProfileTokens())
        await decoder.waitForRequests(1)
        images.remove(accountID: "a")
        await decoder.finish(1)
        await first.value
        #expect(first.isCancelled)
        #expect(images.image(for: "a") == nil)

        let old = images.refresh(accountID: "a", tokens: ProfileTokens())
        await decoder.waitForRequests(2)
        let replacement = images.refresh(accountID: "a", tokens: ProfileTokens())
        await decoder.waitForRequests(3)
        await decoder.finish(2)
        await old.value
        #expect(images.image(for: "a") == nil, "A superseded decode must not publish its pixels")
        images.remove(accountID: "a")
        #expect(replacement.isCancelled, "The old task's cleanup must leave the replacement cancellable")
        await decoder.finish(3)
        await replacement.value
        #expect(images.image(for: "a") == nil)

        let current = images.refresh(accountID: "a", tokens: ProfileTokens())
        await decoder.waitForRequests(4)
        await decoder.finish(4)
        await current.value
        #expect(images.image(for: "a") != nil)
    }

    private func photoData(width: Int = 2, height: Int = 2) throws -> Data {
        let pixels = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ))
        for x in 0..<2 { for y in 0..<2 { pixels.setColor(.systemBlue, atX: x, y: y) } }
        return try #require(pixels.representation(using: .png, properties: [:]))
    }
}

/// Returns prepared pixels after cancellation to exercise the publication gate.
private actor PendingProfileDecode {
    private let result: PreparedAccountProfileImage
    private var count = 0
    private var requests: [Int: CheckedContinuation<PreparedAccountProfileImage?, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(result: PreparedAccountProfileImage) { self.result = result }

    func decode(_ data: Data) async -> PreparedAccountProfileImage? {
        await withCheckedContinuation { continuation in
            count += 1
            requests[count] = continuation
            for (required, waiter) in waiters where count >= required { waiter.resume() }
            waiters.removeAll { count >= $0.0 }
        }
    }

    func waitForRequests(_ required: Int) async {
        guard count < required else { return }
        await withCheckedContinuation { waiters.append((required, $0)) }
    }

    func finish(_ id: Int) { requests.removeValue(forKey: id)?.resume(returning: result) }
}

private struct ProfileTokens: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

private actor ProfileTransport: HTTPTransport {
    let data: Data
    private(set) var requests: [URLRequest] = []

    init(data: Data) { self.data = data }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}

private actor ProfileLoader {
    var result: Result<AccountProfileImages.Photo?, any Error>
    init(result: Result<AccountProfileImages.Photo?, any Error>) { self.result = result }
    func set(_ result: Result<AccountProfileImages.Photo?, any Error>) { self.result = result }
    func load() throws -> AccountProfileImages.Photo? { try result.get() }
}

/// Deliberately ignores cancellation to exercise stale completion protection.
private actor PendingProfileLoader {
    private var count = 0
    private var requests: [Int: CheckedContinuation<AccountProfileImages.Photo?, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load() async -> AccountProfileImages.Photo? {
        await withCheckedContinuation { continuation in
            count += 1
            requests[count] = continuation
            for (required, waiter) in waiters where count >= required { waiter.resume() }
            waiters.removeAll { count >= $0.0 }
        }
    }

    func waitForRequests(_ required: Int) async {
        guard count < required else { return }
        await withCheckedContinuation { waiters.append((required, $0)) }
    }

    func finish(_ id: Int, photo: AccountProfileImages.Photo?) {
        requests.removeValue(forKey: id)?.resume(returning: photo)
    }
}
