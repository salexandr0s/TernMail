import AppKit
import MailStore
import MessageContent
import SwiftUI
import Testing
import WebKit
@testable import Tern

@Suite @MainActor struct MessageWebViewTests {
    @Test(.timeLimit(.minutes(1))) func authoredDarkStylesKeepTextReadableInTheReader() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let cache = try #require(app.cache)
        try await waitFor { mailbox.hasSyncedOnce }
        let key = ThreadKey(accountID: mailbox.account.id, threadID: "t1")
        try #require(await mailbox.open(key, markRead: false))
        let fixture = """
            <style>
              :root { color-scheme: light dark }
              .copy { color: #191c1f }
              .details { background: #f4f5f6 }
              .label { color: #68686a }
              @media (prefers-color-scheme: dark) {
                .copy { color: white !important }
                .details { background: rgba(255,255,255,.05) !important }
                .label { color: #a1a1a3 !important }
              }
            </style>
            <p id="copy" class="copy">Message text</p>
            <div class="details"><span id="label" class="label">To</span><p id="value" class="copy">Recipient</p></div>
            <p id="panel" style="background:#181c24;color:#eef2fa">Sender's dark panel</p>
            <div style="background:black;color:white">
              <span id="nested" style="color:#aabbff">Nested colour</span>
              <span id="wide-gamut" style="color:color(display-p3 0.6 0.7 1)">Wide gamut colour</span>
            </div>
            <a id="button" style="background:#1a73e8;color:white">Sender's button</a>
            <p id="fill" style="background:white;color:#191c1f;-webkit-text-fill-color:#191c1f">Explicit text fill</p>
            <span id="hidden" style="color:transparent;-webkit-text-fill-color:transparent">Hidden preview</span>
            <span id="hidden-current" style="color:transparent">Hidden currentColor preview</span>
            """
        try await cache.write { tx in
            try tx.saveBodies([MessageBodyRecord(accountID: key.accountID, messageID: "m1", html: fixture,
                plainText: nil, fetchedAt: .now)])
        }
        let suite = "MessageWebViewTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(true, forKey: ReadingPreferences.adaptDarkKey)
        settings.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        settings.set("", forKey: ReadingPreferences.lightBackgroundSendersKey)
        settings.set(false, forKey: DomainLogoImages.preferenceKey)
        defer { settings.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: ThreadView(key: key, mailbox: mailbox,
            selectedMessageID: "m1", isReaderActive: true).environment(app).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }

        let (darkView, dark) = try await readerColors(in: controller.view, dark: true)
        expectReadable(dark)
        #expect(dark.samples.first { $0.id == "panel" }?.background == [24, 28, 36])
        #expect(dark.samples.first { $0.id == "panel" }?.fill == "rgb(238, 242, 250)")
        #expect(dark.samples.first { $0.id == "button" }?.background == [26, 115, 232])
        #expect(dark.samples.first { $0.id == "nested" }?.fill == "rgb(170, 187, 255)")
        #expect(dark.wideGamutFill == "color(display-p3 0.6 0.7 1)")
        #expect(dark.hiddenFill == "rgba(0, 0, 0, 0)")
        #expect(dark.hiddenCurrentFill == "rgba(0, 0, 0, 0)")

        window.appearance = NSAppearance(named: .aqua)
        let (_, light) = try await readerColors(in: controller.view, dark: false)
        expectReadable(light)
        #expect(light.samples.first { $0.id == "copy" }?.fill == "rgb(25, 28, 31)")
        #expect(light.samples.first { $0.id == "copy" }?.background == [255, 255, 255])

        window.appearance = NSAppearance(named: .darkAqua)
        _ = try await readerColors(in: controller.view, dark: true)
        var senders = LightBackgroundSenders(storage: "")
        senders.set(true, for: "river@example.invalid")
        settings.set(senders.storage, forKey: ReadingPreferences.lightBackgroundSendersKey)
        let (_, forcedLight) = try await readerColors(in: controller.view, dark: false, excluding: darkView)
        expectReadable(forcedLight)
        #expect(forcedLight.samples.first { $0.id == "copy" }?.fill == "rgb(25, 28, 31)")
        #expect(forcedLight.samples.first { $0.id == "copy" }?.background == [255, 255, 255])
        await app.signOut()
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

private struct ReaderColors: Decodable {
    struct Sample: Decodable {
        let id: String
        let fill: String
        let background: [Double]
        let contrast: Double
    }
    let dark: Bool
    let samples: [Sample]
    let hiddenFill: String
    let hiddenCurrentFill: String
    let wideGamutFill: String
}

@MainActor private func expectReadable(_ colors: ReaderColors) {
    for sample in colors.samples {
        #expect(sample.contrast >= 4.5, "\(sample.id) text/background contrast is \(sample.contrast)")
    }
}

@MainActor private func readerColors(in root: NSView, dark: Bool, excluding previous: WKWebView? = nil) async throws -> (WKWebView, ReaderColors) {
    func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }
    let script = #"""
        (() => {
          if (!document.querySelector('#hidden') || document.readyState !== 'complete') return null;
          const parse = value => value.match(/[\d.]+/g).map(Number);
          const blend = (over, under) => over.slice(0, 3).map((v, i) => v * (over[3] ?? 1) + under[i] * (1 - (over[3] ?? 1)));
          const luminance = rgb => rgb.map(v => v / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4)
            .reduce((sum, v, i) => sum + v * [.2126, .7152, .0722][i], 0);
          const samples = ['copy', 'label', 'value', 'panel', 'button', 'fill', 'nested'].map(id => {
            const element = document.getElementById(id), ancestors = [];
            for (let node = element; node; node = node.parentElement) ancestors.unshift(node);
            const background = ancestors.reduce((under, node) => blend(parse(getComputedStyle(node).backgroundColor), under), [255, 255, 255]);
            const fill = getComputedStyle(element).webkitTextFillColor;
            const text = luminance(blend(parse(fill), background)), back = luminance(background);
            return {id, fill, background, contrast: (Math.max(text, back) + .05) / (Math.min(text, back) + .05)};
          });
          return JSON.stringify({dark: matchMedia('(prefers-color-scheme: dark)').matches, samples,
            hiddenFill: getComputedStyle(document.querySelector('#hidden')).webkitTextFillColor,
            hiddenCurrentFill: getComputedStyle(document.querySelector('#hidden-current')).webkitTextFillColor,
            wideGamutFill: getComputedStyle(document.querySelector('#wide-gamut')).webkitTextFillColor});
        })()
        """#
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    repeat {
        for view in webViews(in: root) where view !== previous {
            if let value = try? await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String,
               let colors = try? JSONDecoder().decode(ReaderColors.self, from: Data(value.utf8)), colors.dark == dark {
                return (view, colors)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < deadline
    throw CocoaError(.coderReadCorrupt)
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
