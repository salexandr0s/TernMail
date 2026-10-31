import AppKit
import MessageContent
import SwiftUI
import Testing
import WebKit
@testable import Tern

@Suite @MainActor struct MessageWebViewTests {
    @Test func anInactiveRetainedRendererDoesNotLoadOrMeasureChangedContent() async throws {
        let height = HeightValue()
        let coordinator = MessageWebView.Coordinator(height: Binding(get: { height.value }, set: { height.value = $0 }))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = ContentSizedWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), configuration: configuration)
        coordinator.setActive(false, in: view)
        coordinator.load("<p>Hidden replacement</p>", in: view)
        coordinator.measure(view)
        try await Task.sleep(for: .milliseconds(20))
        #expect(view.url == nil)
        #expect(height.value == 0)
        #expect(coordinator.needsLoad("<p>Hidden replacement</p>"))
    }

    @Test func mailLinksStayInTernAndWebLinksGoToTheBrowser() throws {
        #expect(MessageWebView.linkAction(for: try #require(URL(string: "mailto:friend@example.com"))) == .mail)
        #expect(MessageWebView.linkAction(for: try #require(URL(string: "tern://conversation?account=a&thread=t"))) == .mail)
        #expect(MessageWebView.linkAction(for: try #require(URL(string: "HTTPS://example.com/page"))) == .browser)
        #expect(MessageWebView.linkAction(for: try #require(URL(string: "javascript:alert(1)"))) == .ignored)
        #expect(MessageWebView.linkAction(for: try #require(URL(string: "file:///etc/hosts"))) == .ignored)
    }

    @Test func bothImagePrivacyRuleSetsCompileInWebKit() async throws {
        _ = try #require(await RemoteContentBlocker.ruleList())
        _ = try #require(await RemoteContentBlocker.ruleList(allowsRemoteImages: true))
    }

    @Test(.timeLimit(.minutes(1))) func inlineImageLoadsOnlyThroughItsOwnImmutableMessageMap() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let resources = InlineResourceMap(resources: [.init(contentID: "logo", partID: "1", mimeType: "image/png", data: png)])
        let own = try #require(resources.url(for: "logo"))
        let foreign = InlineResourceMap(resources: [.init(contentID: "logo", partID: "1", mimeType: "image/png", data: png)])
        let foreignURL = try #require(foreign.url(for: "logo"))
        let height = HeightValue()
        let coordinator = MessageWebView.Coordinator(height: Binding(get: { height.value }, set: { height.value = $0 }))
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(InlineResourceHandler(resources: resources), forURLScheme: InlineResourceMap.scheme)
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "ternHeight")
        configuration.userContentController.addUserScript(WKUserScript(source: MessageWebView.sizingScript(revision: 1),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(try #require(await RemoteContentBlocker.ruleList()))
        let view = ContentSizedWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { view.stopLoading(); window.close() }
        view.navigationDelegate = coordinator
        coordinator.load(MessageDocument.render(plainText: "Image privacy check").html, in: view)
        try await waitFor { height.value > 0 }
        let script = """
            return await new Promise(resolve => {
              const image = new Image(); image.onload = () => resolve(image.naturalWidth > 0);
              image.onerror = () => resolve(false); image.src = source; document.body.append(image);
            });
            """
        let ownLoaded = try await view.callAsyncJavaScript(script, arguments: ["source": own.absoluteString], in: nil, contentWorld: .defaultClient)
        let foreignLoaded = try await view.callAsyncJavaScript(script, arguments: ["source": foreignURL.absoluteString], in: nil, contentWorld: .defaultClient)
        #expect((ownLoaded as? Bool) == true)
        #expect((foreignLoaded as? Bool) == false)
    }

    @Test func zeroDeltaGestureWaitsForMovementAndKeepsItsAxisThroughMomentum() {
        var direction = ScrollDirection()
        let directions = [
            direction.isHorizontal(x: 0, y: 0, startsGesture: true),
            direction.isHorizontal(x: 12, y: 1),
            direction.isHorizontal(x: 0, y: 4),
            direction.isHorizontal(x: 0, y: 0, startsGesture: true),
            direction.isHorizontal(x: 1, y: 12),
            direction.isHorizontal(x: 6, y: 0, isMouseWheel: true),
            direction.isHorizontal(x: 0, y: 6, isMouseWheel: true),
        ]
        #expect(directions == [false, true, true, false, false, true, false])
    }

    @Test func textHeightIsReportedWhileAnImageIsStillLoading() async throws {
        let height = HeightValue()
        let coordinator = MessageWebView.Coordinator(height: Binding(get: { height.value }, set: { height.value = $0 }))
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "ternHeight")
        configuration.userContentController.addUserScript(WKUserScript(source: MessageWebView.sizingScript(revision: 1),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(try #require(await RemoteContentBlocker.ruleList()))
        let images = HeldImageHandler()
        configuration.setURLSchemeHandler(images, forURLScheme: InlineResourceMap.scheme)
        let view = ContentSizedWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 20), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.stopLoading(); window.close() }
        view.navigationDelegate = coordinator
        let text = String(repeating: "The message text can be read while its image loads. ", count: 15)
        let html = MessageDocument.render(plainText: text).html.replacingOccurrences(of: "</body>",
            with: "<img src='tern-message://held/image.png'></body>")
        coordinator.load(html, in: view)
        try await waitFor { images.hasPendingImage && height.value > 100 }
        #expect(view.isLoading)
        #expect(height.value > 100)
        images.finish()
        try await waitFor { !view.isLoading }
    }

    @Test func heightShrinksWhenTextReflowsIntoAWiderPane() async throws {
        let height = HeightValue()
        let coordinator = MessageWebView.Coordinator(height: Binding(get: { height.value }, set: { height.value = $0 }))
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "ternHeight")
        configuration.userContentController.addUserScript(WKUserScript(source: MessageWebView.sizingScript(revision: 1),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = ContentSizedWebView(frame: NSRect(x: 0, y: 0, width: 220, height: 32), configuration: configuration)
        // WebKit suspends layout observers for views outside a window.
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        view.navigationDelegate = coordinator
        let text = String(repeating: "A sentence that wraps when the message pane is narrow. ", count: 12)
        coordinator.load("<html><body style='margin:0;padding:16px'><p>\(text)</p></body></html>", in: view)
        try await waitFor { height.value > 100 }
        let narrow = height.value
        window.setContentSize(NSSize(width: 900, height: narrow))
        coordinator.measure(view)
        try await waitFor { height.value < narrow }
        #expect(height.value < narrow)
        // Inline images and fonts can lay out after navigation has finished.
        _ = try await view.evaluateJavaScript("document.querySelector('p').style.height = '800px'", in: nil, contentWorld: .defaultClient)
        try await waitFor { height.value >= 800 }
    }
}

@MainActor private final class HeightValue { var value: CGFloat = 0 }

@MainActor private final class HeldImageHandler: NSObject, WKURLSchemeHandler {
    private var pending: (any WKURLSchemeTask)?
    var hasPendingImage: Bool { pending != nil }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        pending = urlSchemeTask
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending = nil
    }

    func finish() {
        pending?.didFailWithError(URLError(.resourceUnavailable))
        pending = nil
    }
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(condition(), "WebKit did not report the expected content height")
}
