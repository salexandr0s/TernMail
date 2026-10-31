import AppKit
import ImageIO
import os
import Testing
@testable import Tern

@Suite struct DomainLogoImagesTests {
    @Test func domainUsesPublicSuffixRulesAndNeverPersonalMailOrUntrustedAddressParts() {
        #expect(DomainLogoImages.domain(for: "alerts@MAIL.Bank.CO.UK") == "bank.co.uk")
        #expect(DomainLogoImages.domain(for: "orders@shop.github.io") == "shop.github.io")
        #expect(DomainLogoImages.domain(for: "team@www.ck") == "www.ck")
        #expect(DomainLogoImages.domain(for: "team@news.www.ck") == "www.ck")
        #expect(DomainLogoImages.domain(for: "team@a.b.ck") == "a.b.ck")
        #expect(DomainLogoImages.domain(for: "team@bücher.de") == "xn--bcher-kva.de")
        for address in ["person@gmail.com", "person@outlook.com", "person@proton.me", "person@co.uk",
                        "person@github.io", "person@foo.ck", "person@localhost", "person@127.0.0.1",
                        "person@[::1]", "person@brand.local", "person@brand.com:443", "person@brand.com/path",
                        "Bank <person@attacker.com>", "person@bank.com@attacker.com", "person@bank..com", "@bank.com"] {
            #expect(DomainLogoImages.domain(for: address) == nil, "Unexpected domain: \(address)")
        }
        let suffixes = PublicSuffix(text: "com\nuk\nco.uk\n*.ck\n!www.ck\nio\ngithub.io\n")
        #expect(suffixes.registrableDomain("x.foo.ck") == "x.foo.ck")
        #expect(suffixes.registrableDomain("mail.www.ck") == "www.ck")
        #expect(PublicSuffix(text: "").registrableDomain("bank.com") == nil)
    }

    @Test func discoveryAcceptsOnlySameCompanyHTTPSIconsAndPrefersTouchIcons() throws {
        let page = try #require(URL(string: "https://www.brand.com/start"))
        let html = #"""
        <link rel="icon" href="/small.ico">
        <LINK href='https://assets.brand.com/touch.png?a=1&amp;b=2' REL='apple-touch-icon'>
        <link rel="icon" href="https://brand.com.attacker.com/icon.png">
        <link rel="icon" href="http://brand.com/insecure.png">
        <link rel="icon" href="https://brand.com:8443/alternate.png">
        <link rel="icon" href="https://user:pass@brand.com/private.png">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="/mask.svg">
        <img src="/body.png"><script src="/script.js"></script>
        """#
        let urls = DomainLogoImages.iconURLs(in: html, pageURL: page, domain: "brand.com")
        #expect(urls.map(\.absoluteString) == ["https://assets.brand.com/touch.png?a=1&b=2", "https://www.brand.com/small.ico"])
    }

    @Test func verifiedUnityLegacyDomainsUseTheCanonicalWebsiteAndCache() async throws {
        #expect(DomainLogoImages.domain(for: "no-reply@unity3d.com") == "unity.com")
        #expect(DomainLogoImages.domain(for: "team@news.unity3d.com") == "unity.com")
        #expect(DomainLogoImages.domain(for: "Unity <no-reply@unity3d.com>") == nil)
        #expect(DomainLogoImages.domain(for: "no-reply@unity3d.com.attacker.com") == "attacker.com")
        let transport = LogoTransport(routes: [
            "https://unity.com/": .html(#"<link rel='icon' href='/favicon.ico'>"#),
            "https://unity.com/favicon.ico": .image(try png())
        ])
        let images = DomainLogoImages(cacheDirectory: nil, fetch: { try await transport.fetch($0) })
        let legacy = try #require(await images.data(for: "no-reply@unity3d.com"))
        #expect(await images.data(for: "team@news.unity3d.com") == legacy)
        #expect(await images.data(for: "team@unity.com") == legacy)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "unity.com" })
    }

    @Test func fetchedIconsAreReencodedAndRequestsCarryNoMailIdentity() async throws {
        let transport = LogoTransport(routes: [
            "https://brand.com/": .html(#"<link rel='apple-touch-icon' href='/brand.png'>"#),
            "https://brand.com/brand.png": .image(try png())
        ])
        let images = DomainLogoImages(cacheDirectory: nil, fetch: { try await transport.fetch($0) })
        let data = try #require(await images.data(for: "private-account@news.brand.com"))
        #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithData(data as CFData, nil))) as String? == "public.png")
        let requests = await transport.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Referer") == nil)
            #expect(!request.httpShouldHandleCookies)
            #expect(request.url?.absoluteString.contains("private-account") == false)
            #expect(request.url?.host == "brand.com")
        }
        #expect(await images.data(for: "other@brand.com") == data)
        #expect(await transport.requests.count == 2)
    }

    @Test func redirectsCannotEscapeCompanyAndConventionalICOBecomesPNG() async throws {
        let transport = LogoTransport(routes: [
            "https://brand.com/": .redirect("http://127.0.0.1/private"),
            "https://brand.com/apple-touch-icon.png": .redirect("https://attacker.com/icon"),
            "https://brand.com/favicon.ico": .image(try ico(), type: "image/x-icon")
        ])
        let images = DomainLogoImages(cacheDirectory: nil, fetch: { try await transport.fetch($0) })
        let data = try #require(await images.data(for: "team@brand.com"))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        #expect(await transport.requests.allSatisfy { $0.url?.host == "brand.com" })
    }

    @Test func malformedOversizedAndTrackingImagesDoNotBecomeLogos() throws {
        for data in [Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8),
                     Data(repeating: 0, count: DomainLogoImages.maximumBytes + 1),
                     try png(width: 1, height: 1), try png(width: 4097, height: 8), try png(width: 2049, height: 2049)] {
            #expect(throws: DomainLogoImages.LogoError.self) { try DomainLogoImages.thumbnail(data) }
        }
    }

    @Test func persistedIconsSurviveRestartAndOfflineRefreshAndResetEvictsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LogoClock()
        let transport = LogoTransport(routes: ["https://brand.com/favicon.ico": .image(try png())])
        let first = DomainLogoImages(cacheDirectory: directory, now: { clock.now() }, fetch: { try await transport.fetch($0) })
        let data = try #require(await first.data(for: "one@brand.com"))
        let offline = LogoTransport(offline: true)
        let restarted = DomainLogoImages(cacheDirectory: directory, now: { clock.now() }, fetch: { try await offline.fetch($0) })
        #expect(await restarted.data(for: "two@brand.com") == data)
        #expect(await offline.requests.isEmpty)
        clock.advance(8 * 86400)
        #expect(await restarted.data(for: "two@brand.com") == data)
        #expect(await offline.requests.count == 1)
        #expect(await restarted.data(for: "two@brand.com") == data)
        #expect(await offline.requests.count == 1)
        await restarted.removeAll()
        #expect(await restarted.data(for: "two@brand.com") == nil)
        #expect(await offline.requests.count == 2)
    }

    @Test func missingAndTransientFailuresExpireAtDifferentTimesAndCancellationIsNotCached() async throws {
        let clock = LogoClock()
        let missing = LogoTransport()
        let images = DomainLogoImages(cacheDirectory: nil, now: { clock.now() }, fetch: { try await missing.fetch($0) })
        #expect(await images.data(for: "one@brand.com") == nil)
        let count = await missing.requests.count
        clock.advance(3600)
        #expect(await images.data(for: "two@brand.com") == nil)
        #expect(await missing.requests.count == count)
        clock.advance(6 * 3600)
        #expect(await images.data(for: "two@brand.com") == nil)
        #expect(await missing.requests.count > count)

        let offline = LogoTransport(offline: true)
        let transient = DomainLogoImages(cacheDirectory: nil, now: { clock.now() }, fetch: { try await offline.fetch($0) })
        #expect(await transient.data(for: "one@brand.com") == nil)
        clock.advance(61)
        #expect(await transient.data(for: "one@brand.com") == nil)
        #expect(await offline.requests.count == 2)

        let cancelled = LogoTransport(cancelled: true)
        let retryable = DomainLogoImages(cacheDirectory: nil, fetch: { try await cancelled.fetch($0) })
        #expect(await retryable.data(for: "one@brand.com") == nil)
        #expect(await retryable.data(for: "one@brand.com") == nil)
        #expect(await cancelled.requests.count == 2)
    }

#if DEBUG
    @Test func concurrentRowsShareWorkAndResetRejectsLateResponses() async throws {
        let gate = LogoGate()
        let transport = LogoTransport(routes: ["https://brand.com/favicon.ico": .image(try png())], gate: gate)
        let images = DomainLogoImages(cacheDirectory: nil, fetch: { try await transport.fetch($0) })
        let first = Task { await images.data(for: "one@brand.com") }
        await gate.waitUntilStarted()
        let second = Task { await images.data(for: "two@brand.com") }
        while await images.pendingWaiterCount(for: "one@brand.com") < 2 { await Task.yield() }
        first.cancel()
        await gate.open()
        #expect(await first.value == nil)
        #expect(await second.value != nil)
        #expect(await transport.requests.filter { $0.url?.path == "/" }.count == 1)

        let lateGate = LogoGate()
        let lateTransport = LogoTransport(routes: ["https://brand.com/favicon.ico": .image(try png())], gate: lateGate)
        let resettable = DomainLogoImages(cacheDirectory: nil, fetch: { try await lateTransport.fetch($0) })
        let stale = Task { await resettable.data(for: "one@brand.com") }
        await lateGate.waitUntilStarted()
        await resettable.removeAll()
        await lateGate.open()
        #expect(await stale.value == nil)
        #expect(await resettable.data(for: "two@brand.com") != nil)
        #expect(await lateTransport.requests.filter { $0.url?.path == "/" }.count == 2)
    }
#endif

    @Test func wholeLookupDeadlineCancelsTransportAndUsesShortFailureCache() async {
        let transport = SlowLogoTransport()
        let images = DomainLogoImages(cacheDirectory: nil, loadTimeout: .milliseconds(25), fetch: { try await transport.fetch($0) })
        #expect(await images.data(for: "one@brand.com") == nil)
        #expect(await transport.cancellations == 1)
        #expect(await images.data(for: "two@brand.com") == nil)
        #expect(await transport.calls == 1)
    }

    @Test func cancellingLastWaiterDoesNotCacheItsLateResponse() async throws {
        let gate = LogoGate()
        let transport = LogoTransport(routes: ["https://brand.com/favicon.ico": .image(try png())], gate: gate)
        let images = DomainLogoImages(cacheDirectory: nil, fetch: { try await transport.fetch($0) })
        let cancelled = Task { await images.data(for: "one@brand.com") }
        await gate.waitUntilStarted()
        cancelled.cancel()
        await gate.open()
        #expect(await cancelled.value == nil)
        #expect(await images.data(for: "two@brand.com") != nil)
        #expect(await transport.requests.filter { $0.url?.path == "/" }.count == 2)
    }

    private func png(width: Int = 16, height: Int = 16) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func ico() throws -> Data {
        let image = try png()
        // A standard ICO directory containing a PNG frame (supported since Windows Vista).
        var data = Data([0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0])
        for number in [UInt32(image.count), 22] {
            withUnsafeBytes(of: number.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(image)
        return data
    }
}

private final class LogoClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private actor LogoTransport {
    struct Reply: Sendable {
        let data: Data
        let status: Int
        let headers: [String: String]
        static func html(_ value: String) -> Reply { .init(data: Data(value.utf8), status: 200, headers: ["Content-Type": "text/html"]) }
        static func image(_ data: Data, type: String = "image/png") -> Reply { .init(data: data, status: 200, headers: ["Content-Type": type]) }
        static func redirect(_ url: String) -> Reply { .init(data: Data(), status: 302, headers: ["Location": url]) }
    }
    private let routes: [String: Reply]
    private let offline: Bool
    private let cancelled: Bool
    private let gate: LogoGate?
    private(set) var requests: [URLRequest] = []
    init(routes: [String: Reply] = [:], offline: Bool = false, cancelled: Bool = false, gate: LogoGate? = nil) {
        self.routes = routes; self.offline = offline; self.cancelled = cancelled; self.gate = gate
    }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        if cancelled { throw CancellationError() }
        let url = try #require(request.url)
        if url.path == "/", let gate { await gate.wait() }
        let reply = routes[url.absoluteString] ?? .init(data: Data(), status: 404, headers: [:])
        return (reply.data, try #require(HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)))
    }
}

private actor SlowLogoTransport {
    private(set) var calls = 0
    private(set) var cancellations = 0
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancellations += 1; throw error }
        throw URLError(.timedOut)
    }
}

/// Intentionally ignores cancellation so reset must reject stale results itself.
private actor LogoGate {
    private var isOpen = false
    private var started = false
    private var requests: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        started = true
        observers.forEach { $0.resume() }; observers.removeAll()
        if !isOpen { await withCheckedContinuation { requests.append($0) } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { observers.append($0) } }
    }
    func open() {
        isOpen = true
        requests.forEach { $0.resume() }; requests.removeAll()
    }
}
