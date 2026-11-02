import AppKit
import GmailAPI
import ImageIO
import Observation

/// Optional Google profile photos. Mail and sign-in do not wait for them.
@MainActor
@Observable
final class AccountProfileImages {
    struct Photo: Sendable {
        let data: Data
        var cacheURLs: [URL] = []
    }

    typealias Loader = @Sendable (String, any AccessTokenProvider) async throws -> Photo?

    static let shared = AccountProfileImages()

    private var images: [String: NSImage] = [:]
    @ObservationIgnored private let load: Loader
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var cachedURLs: [String: Set<URL>] = [:]

    init(load: @escaping Loader = AccountProfileImages.loadGooglePhoto) {
        self.load = load
    }

    func image(for accountID: String) -> NSImage? { images[accountID] }

    @discardableResult
    func refresh(accountID: String, tokens: any AccessTokenProvider) -> Task<Void, Never> {
        tasks[accountID]?.cancel()
        let generation = UUID()
        generations[accountID] = generation
        let load = load
        let task = Task { [weak self] in
            do {
                let photo = try await load(accountID, tokens)
                guard let self, generations[accountID] == generation, !Task.isCancelled else {
                    Self.evict(photo?.cacheURLs ?? [])
                    return
                }
                defer { tasks[accountID] = nil }
                guard let photo else {
                    images[accountID] = nil
                    return
                }
                cachedURLs[accountID, default: []].formUnion(photo.cacheURLs)
                guard let image = Self.decode(photo.data) else { return }
                images[accountID] = image
            } catch {
                // A failed refresh keeps the last photo, or the UI's initials.
                guard let self, generations[accountID] == generation else { return }
                tasks[accountID] = nil
            }
        }
        tasks[accountID] = task
        return task
    }

    /// Invalidating the generation also rejects loaders that ignore cancellation.
    func remove(accountID: String) {
        generations[accountID] = nil
        tasks.removeValue(forKey: accountID)?.cancel()
        images[accountID] = nil
        Self.evict(Array(cachedURLs.removeValue(forKey: accountID) ?? []))
    }

    func removeAll() {
        for accountID in Set(generations.keys).union(images.keys).union(cachedURLs.keys) {
            remove(accountID: accountID)
        }
    }

#if DEBUG || TERN_PERFORMANCE
    func setAuditImage(_ image: NSImage, for accountID: String) {
        guard ProcessInfo.processInfo.arguments.contains("--ui-audit") else { return }
        remove(accountID: accountID)
        images[accountID] = image
    }
#endif

    private static func decode(_ data: Data) -> NSImage? {
        guard data.count <= 5 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: Google profile

    private struct UserInfo: Decodable {
        let sub: String
        let picture: URL?
    }

    enum LoadError: Error {
        case invalidResponse, identityMismatch, invalidPictureURL
    }

    /// Kept separate from the picture session so OAuth never reaches an image host.
    nonisolated static func loadGooglePhoto(
        accountID: String, tokens: any AccessTokenProvider,
        profileTransport: any HTTPTransport = profileSession,
        pictureTransport: any HTTPTransport = pictureSession
    ) async throws -> Photo? {
        guard let endpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo") else {
            throw LoadError.invalidResponse
        }
        for forceRefresh in [false, true] {
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
            let token = try await tokens.accessToken(forceRefresh: forceRefresh)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await profileTransport.send(request)
            if response.statusCode == 401, !forceRefresh { continue }
            guard response.statusCode == 200, response.url?.scheme?.lowercased() == "https",
                  response.url?.host?.lowercased() == endpoint.host else { throw LoadError.invalidResponse }
            let profile = try JSONDecoder().decode(UserInfo.self, from: data)
            guard profile.sub == accountID else { throw LoadError.identityMismatch }
            guard let url = profile.picture else { return nil }
            guard url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw LoadError.invalidPictureURL }
            try Task.checkCancellation()
            var pictureRequest = URLRequest(url: url)
            pictureRequest.setValue("image/*", forHTTPHeaderField: "Accept")
            let (picture, pictureResponse) = try await pictureTransport.send(pictureRequest)
            guard pictureResponse.statusCode == 200,
                  pictureResponse.url?.scheme?.lowercased() == "https" else { throw LoadError.invalidResponse }
            return Photo(data: picture, cacheURLs: [url, pictureResponse.url].compactMap { $0 })
        }
        throw LoadError.invalidResponse
    }

    nonisolated private static func loadGooglePhoto(_ accountID: String, _ tokens: any AccessTokenProvider) async throws -> Photo? {
        try await loadGooglePhoto(accountID: accountID, tokens: tokens)
    }

    nonisolated private static let profileSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(
            configuration: configuration,
            delegate: ProfileImageRedirectPolicy(requiredHost: "openidconnect.googleapis.com"), delegateQueue: nil
        )
    }()

    /// Memory-only so signing out cannot leave photos cached by an earlier launch.
    nonisolated private static let pictureCache = URLCache(
        memoryCapacity: 4 * 1_024 * 1_024, diskCapacity: 0, diskPath: nil
    )

    nonisolated private static let pictureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = pictureCache
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(
            configuration: configuration,
            delegate: ProfileImageRedirectPolicy(requiredHost: nil), delegateQueue: nil
        )
    }()

    nonisolated private static func evict(_ urls: [URL]) {
        for url in urls { pictureCache.removeCachedResponse(for: URLRequest(url: url)) }
    }
}

/// Userinfo stays on Google's host; photos may redirect only over HTTPS.
private final class ProfileImageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let requiredHost: String?

    init(requiredHost: String?) { self.requiredHost = requiredHost }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              requiredHost == nil || url.host?.lowercased() == requiredHost else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
