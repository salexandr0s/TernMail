import AppKit
import Foundation
import MessageContent
import Network
import SwiftUI
import SyncEngine
import Testing
import WebKit
@testable import Tern

@Suite @MainActor struct RemoteImageSecurityTests {
    @Test func handlerRequiresPreparedMembershipAndUpdatesScopeAndConsent() async throws {
        let original = try #require(URL(string: "https://images.example.com/photo.png"))
        let other = try #require(URL(string: "https://images.example.com/unlisted.png"))
        let first = InlineResourceMap()
        let second = InlineResourceMap()
        let fetches = ImageFetchGate()
        let limiter = RemoteImageLoadLimiter(maximumConcurrentLoads: 1)
        let handler = RemoteImageHandler(scope: first.scope, enabled: false, allowedURLs: [original], limiter: limiter) {
            try await fetches.fetch($0)
        }
        let view = WKWebView()
        let originalURL = try #require(RemoteImageResourceURL.make(original, scope: first.scope))
        let disabled = ImageSchemeRequest(originalURL)
        handler.webView(view, start: disabled)
        #expect(disabled.failures == 1)
        handler.update(scope: first.scope, enabled: true, allowedURLs: [original])
        let unlisted = ImageSchemeRequest(try #require(RemoteImageResourceURL.make(other, scope: first.scope)))
        handler.webView(view, start: unlisted)
        #expect(unlisted.failures == 1)
        #expect(await fetches.started.isEmpty)

        handler.update(scope: second.scope, enabled: true, allowedURLs: [original])
        let stale = ImageSchemeRequest(originalURL)
        handler.webView(view, start: stale)
        #expect(stale.failures == 1)
        let current = ImageSchemeRequest(try #require(RemoteImageResourceURL.make(original, scope: second.scope)))
        handler.webView(view, start: current)
        try await eventually { await fetches.started == [original] }
        await fetches.release(original)
        try await eventually { current.finished == 1 }
        #expect(current.responses == 1)
        #expect(current.failures == 0)
    }

    @Test func hidingAndRevokingImagesCancelFetchesAndRejectLateResults() async throws {
        for hidesReader in [true, false] {
            let original = try #require(URL(string: "https://images.example.com/photo.png"))
            let scope = InlineResourceMap().scope
            let fetches = ImageFetchGate()
            let limiter = RemoteImageLoadLimiter(maximumConcurrentLoads: 1)
            let handler = RemoteImageHandler(scope: scope, enabled: true, allowedURLs: [original], limiter: limiter) {
                try await fetches.fetch($0)
            }
            let view = WKWebView()
            let url = try #require(RemoteImageResourceURL.make(original, scope: scope))
            let pending = ImageSchemeRequest(url)
            handler.webView(view, start: pending)
            try await eventually { await fetches.started.count == 1 }
            if hidesReader { handler.setActive(false) }
            else { handler.update(scope: scope, enabled: false, allowedURLs: [original]) }
            #expect(pending.failures == 1)
            let afterRevocation = ImageSchemeRequest(url)
            handler.webView(view, start: afterRevocation)
            #expect(afterRevocation.failures == 1)
            // The injected fetch deliberately ignores cancellation until released.
            await fetches.release(original)
            try await eventually { limiter.activeLoadCount == 0 }
            #expect(pending.responses == 0)
            #expect(pending.finished == 0)
            #expect(pending.failures == 1)
        }
    }

    @Test func nativeLoadLimitCancelsQueuedWorkWithoutStartingItsFetch() async throws {
        let urls = try (0..<3).map { try #require(URL(string: "https://images.example.com/\($0).png")) }
        let limiter = RemoteImageLoadLimiter(maximumConcurrentLoads: 1)
        let fetches = ImageFetchGate()
        let first = Task { try await limiter.perform { try await fetches.fetch(urls[0]) } }
        try await eventually { await fetches.started == [urls[0]] }
        let cancelled = Task { try await limiter.perform { try await fetches.fetch(urls[1]) } }
        try await eventually { limiter.queuedLoadCount == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let next = Task { try await limiter.perform { try await fetches.fetch(urls[2]) } }
        try await eventually { limiter.queuedLoadCount == 1 }
        #expect(limiter.activeLoadCount == 1)
        await fetches.release(urls[0])
        _ = try await first.value
        try await eventually { await fetches.started == [urls[0], urls[2]] }
        await fetches.release(urls[2])
        _ = try await next.value
        #expect(limiter.activeLoadCount == 0)
        #expect(limiter.queuedLoadCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func escapedCSSCannotOpenALoopbackConnectionAfterImageConsent() async throws {
        let probe = try ImageConnectionProbe()
        let port = try await probe.start()
        defer { probe.stop() }
        let html = "<div id='probe' style='width:200px;height:200px;background:u\\72l(https://127.0.0.1:\(port)/image.png)'>Image</div>"
        let control = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        control.loadHTMLString(html, baseURL: nil)
        try await eventually { probe.connections > 0 }
        control.stopLoading()
        try await Task.sleep(for: .milliseconds(150))
        let before = probe.connections

        let rendered = MessageDocument.render(html: html, policy: .init(allowsRemoteImages: true))
        #expect(rendered.html.contains("u\\72l("))
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(try #require(await RemoteContentBlocker.ruleList(allowsRemoteImages: true)))
        let protected = WKWebView(frame: control.frame, configuration: configuration)
        defer { protected.stopLoading() }
        protected.loadHTMLString(rendered.html, baseURL: nil)
        try await eventually { protected.url != nil && !protected.isLoading }
        let background = try await protected.evaluateJavaScript("getComputedStyle(document.getElementById('probe')).backgroundImage",
            in: nil, contentWorld: .defaultClient) as? String
        #expect(background?.contains("127.0.0.1") == true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(probe.connections == before)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }
}

private actor ImageFetchGate {
    private(set) var started: [URL] = []
    private var waiting: [URL: CheckedContinuation<PinnedRemoteImage, Never>] = [:]

    func fetch(_ url: URL) async throws -> PinnedRemoteImage {
        started.append(url)
        return await withCheckedContinuation { waiting[url] = $0 }
    }

    func release(_ url: URL) {
        waiting.removeValue(forKey: url)?.resume(returning: PinnedRemoteImage(data: Data([1, 2, 3]), mimeType: "image/png"))
    }
}

@MainActor private final class ImageSchemeRequest: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    private(set) var failures = 0
    private(set) var responses = 0
    private(set) var finished = 0
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { responses += 1 }
    func didReceive(_ data: Data) {}
    func didFinish() { finished += 1 }
    func didFailWithError(_ error: any Error) { failures += 1 }
}

@MainActor private final class ImageConnectionProbe {
    private let listener: NWListener
    private var ready: CheckedContinuation<UInt16, any Error>?
    private(set) var connections = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                case .failed(let error): self.ready?.resume(throwing: error); self.ready = nil
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.connections += 1; connection.start(queue: .main); connection.cancel() }
        }
        return try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }

    func stop() { listener.cancel() }
}
