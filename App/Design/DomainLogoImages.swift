import CryptoKit
import Darwin
import Foundation
import ImageIO
import os

/// Website icons are optional, shared by domain, and separate from account/contact data.
actor DomainLogoImages {
    nonisolated static let preferenceKey = "showCompanyLogos"
    static let shared = DomainLogoImages()
    nonisolated static let maximumBytes = 1_048_576
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    enum LogoError: Error { case invalidURL, invalidResponse, invalidImage, tooLarge }

    private struct Entry: Codable {
        let domain: String
        let createdAt: Date
        let expiresAt: Date
        let data: Data?
    }
    private struct Pending {
        let id: UUID
        let task: Task<Data?, Never>
        var waiters: [UUID: OSAllocatedUnfairLock<Bool>]
    }
    private enum Outcome { case found(Data), missing, unavailable, cancelled }

    private let fetch: Fetch
    private let directory: URL?
    private let now: @Sendable () -> Date
    private let loadTimeout: Duration
    private var entries: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]
    private var activeLoads = 0
    private var queue: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(cacheDirectory: URL? = DomainLogoImages.defaultDirectory,
         now: @escaping @Sendable () -> Date = Date.init,
         loadTimeout: Duration = .seconds(15),
         fetch: @escaping Fetch = DomainLogoImages.stream) {
        self.directory = cacheDirectory
        self.fetch = fetch
        self.now = now
        self.loadTimeout = loadTimeout
    }

    nonisolated static func domain(for address: String) -> String? {
        guard address.count <= 320, !address.contains(where: \.isWhitespace) else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              let domain = PublicSuffix.shared.registrableDomain(String(parts[1])),
              !personalDomains.contains(domain) else { return nil }
        // Unity's legacy website redirects to its current domain. Keep brand aliases explicit.
        return canonicalDomains[domain] ?? domain
    }

    nonisolated private static let canonicalDomains = ["unity3d.com": "unity.com"]

    func data(for address: String) async -> Data? {
        guard !Task.isCancelled, let domain = Self.domain(for: address) else { return nil }
        let waiter = UUID()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            guard !cancelled.withLock({ $0 }) else { return nil }
            if let entry = cached(domain), entry.expiresAt > now() { return entry.data }
            let task: Task<Data?, Never>
            if var existing = pending[domain] {
                existing.waiters[waiter] = cancelled
                pending[domain] = existing
                task = existing.task
            } else {
                let generation = UUID()
                let fetch = fetch
                let timeout = loadTimeout
                task = Task {
                    guard await acquireSlot(generation) else { return nil }
                    defer { releaseSlot() }
                    guard !Task.isCancelled, hasActiveWaiters(domain, generation: generation) else {
                        return complete(domain, generation: generation, outcome: .cancelled)
                    }
                    let outcome = await Self.load(domain: domain, timeout: timeout, fetch: fetch)
                    return complete(domain, generation: generation, outcome: outcome)
                }
                pending[domain] = Pending(id: generation, task: task, waiters: [waiter: cancelled])
            }
            let result = await task.value
            return Task.isCancelled ? nil : result
        } onCancel: {
            cancelled.withLock { $0 = true }
            Task { await self.cancel(domain: domain, waiter: waiter) }
        }
    }

    /// Cancels queued loads and makes ignored-cancellation completions obsolete.
    func removeAll() {
        let tasks = pending.values.map(\.task)
        pending.removeAll()
        tasks.forEach { $0.cancel() }
        entries.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

#if DEBUG
    func pendingWaiterCount(for address: String) -> Int {
        guard let domain = Self.domain(for: address) else { return 0 }
        return pending[domain]?.waiters.count ?? 0
    }
#endif

    private func cancel(domain: String, waiter: UUID) {
        guard var value = pending[domain] else { return }
        value.waiters[waiter] = nil
        if value.waiters.isEmpty {
            pending[domain] = nil
            value.task.cancel()
        } else { pending[domain] = value }
    }

    private func acquireSlot(_ id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeLoads < 4 { activeLoads += 1; return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { queue.append((id, $0)) }
        } onCancel: { Task { await self.cancelQueued(id) } }
    }

    private func cancelQueued(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.0 == id }) else { return }
        queue.remove(at: index).1.resume(returning: false)
    }

    private func releaseSlot() {
        if queue.isEmpty { activeLoads -= 1 }
        else { queue.removeFirst().1.resume(returning: true) }
    }

    private func hasActiveWaiters(_ domain: String, generation: UUID) -> Bool {
        guard let value = pending[domain], value.id == generation else { return false }
        return value.waiters.values.contains { !$0.withLock { $0 } }
    }

    private func complete(_ domain: String, generation: UUID, outcome: Outcome) -> Data? {
        guard pending[domain]?.id == generation else { return nil }
        let shouldCache = !Task.isCancelled && hasActiveWaiters(domain, generation: generation)
        pending[domain] = nil
        guard shouldCache else { return nil }
        let date = now()
        let old = cached(domain)
        let fallback = old.flatMap { $0.createdAt > date.addingTimeInterval(-30 * 86400) ? $0 : nil }
        let entry: Entry
        switch outcome {
        case .cancelled: return nil
        case .found(let data):
            entry = Entry(domain: domain, createdAt: date, expiresAt: date.addingTimeInterval(7 * 86400), data: data)
        case .missing, .unavailable:
            let delay: TimeInterval = if case .missing = outcome { 6 * 3600 } else { 60 }
            entry = Entry(domain: domain, createdAt: fallback?.createdAt ?? date,
                          expiresAt: date.addingTimeInterval(delay), data: fallback?.data)
        }
        entries[domain] = entry
        if entries.count > 256, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries[oldest] = nil
        }
        persist(entry)
        return entry.data
    }

    private func cached(_ domain: String) -> Entry? {
        if let entry = entries[domain] { return entry }
        guard let url = cacheURL(domain), let bytes = try? Data(contentsOf: url), bytes.count <= Self.maximumBytes * 2,
              let entry = try? JSONDecoder().decode(Entry.self, from: bytes), entry.domain == domain,
              entry.data == nil || (try? Self.thumbnail(entry.data ?? Data())) != nil else { return nil }
        entries[domain] = entry
        return entry
    }

    private func persist(_ entry: Entry) {
        guard let directory, let url = cacheURL(entry.domain), let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            let values = files.compactMap { url -> (URL, Int, Date)? in
                guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (url, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var count = values.count
            var bytes = values.reduce(0) { $0 + $1.1 }
            for (file, size, _) in values where count > 128 || bytes > 16 * 1_024 * 1_024 {
                try? FileManager.default.removeItem(at: file)
                count -= 1; bytes -= size
            }
        } catch { /* Cache failures leave the in-memory icon available. */ }
    }

    private func cacheURL(_ domain: String) -> URL? {
        let key = SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(key).appendingPathExtension("json")
    }

    nonisolated private static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Tern/DomainLogos", isDirectory: true)

    nonisolated private static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "hotmail.co.uk", "hotmail.fr", "hotmail.de",
        "live.com", "live.co.uk", "live.de", "msn.com", "yahoo.com", "yahoo.co.uk", "yahoo.de", "yahoo.fr",
        "ymail.com", "rocketmail.com", "icloud.com", "me.com", "mac.com", "aol.com", "aim.com",
        "proton.me", "protonmail.com", "pm.me", "tuta.com", "tutanota.com", "tutanota.de", "fastmail.com",
        "gmx.com", "gmx.net", "gmx.de", "gmx.at", "web.de", "mail.com", "hey.com", "yandex.com", "yandex.ru",
        "qq.com", "163.com", "126.com", "zoho.com", "mail.ru", "inbox.ru", "list.ru", "bk.ru"
    ]

    nonisolated static func isAllowed(_ url: URL, domain: String) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host,
              PublicSuffix.shared.registrableDomain(host) == domain else { return false }
        return url.absoluteString.count <= 2_048
    }

    nonisolated private static func load(domain: String, timeout: Duration, fetch: @escaping Fetch) async -> Outcome {
        let expired = OSAllocatedUnfairLock(initialState: false)
        let operation = Task { await discover(domain: domain, fetch: fetch) }
        let watchdog = Task {
            do {
                try await Task.sleep(for: timeout)
                expired.withLock { $0 = true }
                operation.cancel()
            } catch { /* Completed or cancelled lookups remove their timer. */ }
        }
        let outcome = await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
        watchdog.cancel()
        return expired.withLock { $0 } ? .unavailable : outcome
    }

    nonisolated private static func discover(domain: String, fetch: Fetch) async -> Outcome {
        guard let root = URL(string: "https://" + domain + "/") else { return .missing }
        var unavailable = false
        var candidates: [URL] = []
        do {
            let (data, response) = try await resource(root, domain: domain, accept: "text/html", fetch: fetch)
            if response.statusCode == 200, response.mimeType?.lowercased() == "text/html" {
                candidates = iconURLs(in: String(decoding: data.prefix(262_144), as: UTF8.self),
                                      pageURL: response.url ?? root, domain: domain)
            } else if response.statusCode == 429 || response.statusCode >= 500 { unavailable = true }
        } catch is CancellationError { return .cancelled }
        catch let error as URLError where error.code == .cancelled { return .cancelled }
        catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost].contains(error.code) { return .unavailable }
        catch { unavailable = true }
        for host in [domain, "www." + domain] {
            for path in ["/apple-touch-icon.png", "/favicon.ico"] {
                if let url = URL(string: "https://" + host + path), !candidates.contains(url) { candidates.append(url) }
            }
        }
        for url in candidates {
            if Task.isCancelled { return .cancelled }
            do {
                let (data, response) = try await resource(url, domain: domain,
                    accept: "image/png,image/jpeg,image/gif,image/webp,image/x-icon,image/vnd.microsoft.icon", fetch: fetch)
                guard response.statusCode == 200 else {
                    if response.statusCode == 429 || response.statusCode >= 500 { unavailable = true }
                    continue
                }
                let accepted = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/x-icon", "image/vnd.microsoft.icon", "application/octet-stream"]
                guard accepted.contains(response.mimeType?.lowercased() ?? ""), let clean = try? thumbnail(data) else { continue }
                return .found(clean)
            } catch is CancellationError { return .cancelled }
            catch let error as URLError where error.code == .cancelled { return .cancelled }
            catch { unavailable = true }
        }
        return unavailable ? .unavailable : .missing
    }

    /// Only website-declared icon links are considered; page scripts, images and manifests never run.
    nonisolated static func iconURLs(in html: String, pageURL: URL, domain: String) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: #"(?is)<link\b[^>]{0,4096}>"#),
              let attributes = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        let source = html as NSString
        var icons: [(URL, Bool)] = []
        for match in tags.matches(in: html, range: NSRange(location: 0, length: source.length)).prefix(64) {
            let tag = source.substring(with: match.range)
            let nsTag = tag as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
                let key = nsTag.substring(with: attribute.range(at: 1)).lowercased()
                for index in 2...4 where attribute.range(at: index).location != NSNotFound {
                    values[key] = nsTag.substring(with: attribute.range(at: index))
                }
            }
            let rel = Set((values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            guard !rel.isDisjoint(with: ["icon", "apple-touch-icon", "apple-touch-icon-precomposed"]),
                  let href = values["href"], let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: pageURL)?.absoluteURL,
                  isAllowed(url, domain: domain), url.pathExtension.lowercased() != "svg" else { continue }
            if !icons.contains(where: { $0.0 == url }) { icons.append((url, rel.contains("apple-touch-icon"))) }
        }
        return Array(icons.sorted { $0.1 && !$1.1 }.prefix(3).map(\.0))
    }

    nonisolated private static func resource(_ initial: URL, domain: String, accept: String, fetch: Fetch) async throws -> (Data, HTTPURLResponse) {
        var url = initial
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard isAllowed(url, domain: domain) else { throw LogoError.invalidURL }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpShouldHandleCookies = false
            request.setValue(accept, forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard data.count <= maximumBytes, let final = response.url, isAllowed(final, domain: domain) else { throw LogoError.invalidResponse }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let target = URL(string: location, relativeTo: final)?.absoluteURL,
                      isAllowed(target, domain: domain) else { throw LogoError.invalidURL }
                url = target
            } else { return (data, response) }
        }
        throw LogoError.invalidResponse
    }

    nonisolated static func thumbnail(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "com.microsoft.ico"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width >= 8, height >= 8, width <= 4096, height <= 4096, width * height <= 4_194_304,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary) else { throw LogoError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw LogoError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw LogoError.invalidImage }
        return output as Data
    }

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: DomainLogoRedirectPolicy(), delegateQueue: nil)
    }()

    nonisolated static func stream(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let host = request.url?.host, isPublicHost(host) else { throw LogoError.invalidURL }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw LogoError.invalidResponse }
        let html = request.value(forHTTPHeaderField: "Accept") == "text/html"
        guard html || http.expectedContentLength <= maximumBytes else { throw LogoError.tooLarge }
        let limit = html ? 262_144 : maximumBytes
        var data = Data()
        for try await byte in bytes {
            if data.count == limit {
                if html { break }
                throw LogoError.tooLarge
            }
            data.append(byte)
        }
        return (data, http)
    }

    /// Reject all non-public DNS answers before a request. URLSession still performs its own resolution.
    nonisolated private static func isPublicHost(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let item = cursor {
            guard let address = item.pointee.ai_addr else { return false }
            if address.pointee.sa_family == AF_INET {
                let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
                let a = value >> 24, b = (value >> 16) & 255
                let c = (value >> 8) & 255
                guard a != 0, a != 10, a != 127, a < 224, !(a == 100 && (64...127).contains(b)),
                      !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
                      !(a == 192 && (b == 168 || b == 0)), !(a == 198 && (b == 18 || b == 19)),
                      !(a == 198 && b == 51 && c == 100), !(a == 203 && b == 0 && c == 113) else { return false }
            } else if address.pointee.sa_family == AF_INET6 {
                let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                // Global unicast only; mapped IPv4, loopback, link-local and unique-local fail closed.
                guard bytes.first.map({ ($0 & 0xe0) == 0x20 }) == true,
                      !(bytes[0] == 0x20 && bytes[1] == 0x02),
                      !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2),
                      !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) else { return false }
            } else { return false }
            cursor = item.pointee.ai_next
        }
        return true
    }
}

private final class DomainLogoRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
