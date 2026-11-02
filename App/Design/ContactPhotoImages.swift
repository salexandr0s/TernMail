import AppKit
import ImageIO
import MailStore
import Foundation

/// Contact photo requests never carry account tokens, cookies or credentials.
enum ContactPhotoImages {
    static let maximumBytes = 1_048_576
    static let maximumPixels = 4_194_304
    static let maximumDimension = 4_096
    static let thumbnailDimension = 160
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    enum PhotoError: Error { case invalidURL, invalidResponse, invalidImage, tooLarge }

    static func isTrustedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return ["googleusercontent.com", "ggpht.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func loadThumbnail(url: URL, fetch: Fetch = stream) async throws -> Data {
        guard isTrustedURL(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PhotoError.invalidURL }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "sz" }
        items.append(URLQueryItem(name: "sz", value: String(thumbnailDimension)))
        components.queryItems = items
        guard let sizedURL = components.url else { throw PhotoError.invalidURL }
        var request = URLRequest(url: sizedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("image/png,image/jpeg,image/gif,image/webp", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard response.statusCode == 200, let finalURL = response.url, isTrustedURL(finalURL),
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(response.mimeType?.lowercased() ?? "") else {
            throw PhotoError.invalidResponse
        }
        guard data.count <= maximumBytes else { throw PhotoError.tooLarge }
        return try thumbnail(data)
    }

    /// Re-encoding a bounded first frame discards animation and untrusted image metadata.
    static func thumbnail(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              width * height <= maximumPixels else { throw PhotoError.invalidImage }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw PhotoError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw PhotoError.invalidImage }
        return output as Data
    }

    @MainActor
    static func image(for record: ContactPhotoRecord, address: String, cache: MailCache, accounts: AccountStore,
                      contextID: String = "") async -> NSImage? {
        do {
            guard try await isEnabled(record.accountID, accounts: accounts) else {
                ContactThumbnailCache.shared.remove(accountID: record.accountID)
                return nil
            }
            if let cached = record.data, let date = record.fetchedAt, date > Date().addingTimeInterval(-7 * 86400) {
                do {
                    let image = try await ContactThumbnailCache.shared.image(
                        for: ContactPhotoCacheKey(record, contextID: contextID), data: cached)
                    guard try await cache.contactPhoto(accountID: record.accountID, address: address)?.version == record.version,
                          try await isEnabled(record.accountID, accounts: accounts), !Task.isCancelled else { return nil }
                    return image
                } catch is CancellationError { return nil }
                catch { /* An invalid disk thumbnail is replaced from its trusted source. */ }
            }
            let data = try await loadThumbnail(url: record.url)
            try Task.checkCancellation()
            guard try await isEnabled(record.accountID, accounts: accounts),
                  try await cache.storeContactPhoto(data, for: record) else { return nil }
            try Task.checkCancellation()
            guard try await isEnabled(record.accountID, accounts: accounts),
                  let current = try await cache.contactPhoto(accountID: record.accountID, address: address),
                  current.version == record.version else { return nil }
            let image = try await ContactThumbnailCache.shared.image(for: ContactPhotoCacheKey(current, contextID: contextID), data: data)
            guard try await isEnabled(record.accountID, accounts: accounts),
                  try await cache.contactPhoto(accountID: record.accountID, address: address)?.version == record.version,
                  !Task.isCancelled else { return nil }
            return image
        } catch { return nil }
    }

    private static func isEnabled(_ accountID: String, accounts: AccountStore) async throws -> Bool {
        try await accounts.accounts().first(where: { $0.id == accountID })?.enabledFeatures.contains("contacts") == true
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: ContactPhotoRedirectPolicy(), delegateQueue: nil)
    }()

    static func stream(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= maximumBytes else { throw PhotoError.invalidResponse }
        var result = Data()
        for try await byte in bytes {
            guard result.count < maximumBytes else { throw PhotoError.tooLarge }
            result.append(byte)
        }
        return (result, http)
    }
}

/// Photo URLs returned by People are direct assets; redirect failures keep the initials fallback.
private final class ContactPhotoRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
