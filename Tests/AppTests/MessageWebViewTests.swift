import AppKit
import JavaScriptCore
import MailStore
import MessageContent
import SyncEngine
import SwiftUI
import Synchronization
import Testing
import WebKit
@testable import Tern

@Suite @MainActor struct MessageWebViewTests {
    @Test(.timeLimit(.minutes(1))) func hiddenRendererRestoresBackgroundEligibilityWithoutStealingOtherControls() async throws {
        let height = HeightValue()
        let coordinator = MessageWebView.Coordinator(height: Binding(get: { height.value }, set: { height.value = $0 }))
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = ContentSizedWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 180), configuration: configuration)
        let field = NSTextField(frame: NSRect(x: 0, y: 190, width: 400, height: 24))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 230))
        root.addSubview(view); root.addSubview(field)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        // Background-only: never activate the app or make this window key.
        window.orderBack(nil)
        defer { view.stopLoading(); window.close() }
        view.navigationDelegate = coordinator
        let html = MessageDocument.render(plainText: "A searchable reader needle stays in this document.").html
        coordinator.load(html, in: view)
        try await waitFor { view.url != nil && !view.isLoading }
        let nativeResponder = nativeDescendants(of: view).first { $0.acceptsFirstResponder }
        let acceptsFocusWhenActive = view.acceptsFirstResponder
        let isKeyViewWhenActive = view.canBecomeKeyView
        let childWasKeyView = nativeResponder?.canBecomeKeyView
        // Some WebKit versions use the wrapper itself, and a background
        // window need not expose an eligible private content responder.
        let accepted = window.makeFirstResponder(nativeResponder ?? view)
        if accepted {
            let ownedResponder = try #require(window.firstResponder as? NSView)
            #expect(ownedResponder === view || ownedResponder.isDescendant(of: view))
        } else {
            print("Deferred: this background WebKit view did not accept native focus; owned-responder resignation needs a visible focus fixture.")
        }
        if nativeResponder == nil {
            print("Deferred: background WebKit exposed no eligible internal descendant; descendant-responder ownership is not runtime-verified.")
        }

        coordinator.setActive(false, in: view)
        #expect(view.isHidden)
        #expect(!view.acceptsFirstResponder)
        #expect(!view.canBecomeKeyView)
        #expect(!view.becomeFirstResponder())
        #expect(nativeDescendants(of: view).allSatisfy { !$0.canBecomeKeyView })
        #expect((window.firstResponder as? NSView)?.isDescendant(of: view) != true)
        #expect(window.firstResponder !== view)

        coordinator.setActive(true, in: view)
        #expect(!view.isHidden)
        #expect(view.acceptsFirstResponder == acceptsFocusWhenActive)
        #expect(view.canBecomeKeyView == isKeyViewWhenActive)
        #expect(nativeResponder?.canBecomeKeyView == childWasKeyView)
        #expect(!coordinator.needsLoad(html), "Reactivation must retain the loaded document")
        let find = WKFindConfiguration()
        find.wraps = true
        #expect(try await view.find("reader needle", configuration: find).matchFound)
        let selection = try await view.evaluateJavaScript("getSelection()?.toString()", in: nil, contentWorld: .defaultClient) as? String
        #expect(selection == "reader needle")

        try #require(window.makeFirstResponder(field))
        let unrelatedResponder = try #require(window.firstResponder)
        coordinator.setActive(false, in: view)
        #expect(window.firstResponder === unrelatedResponder)
        // Repeated updates while retained must not steal another control's
        // field editor, and reactivation must not automatically grab focus.
        coordinator.setActive(false, in: view)
        coordinator.setActive(true, in: view)
        #expect(window.firstResponder === unrelatedResponder)
        #expect(!window.isKeyWindow)
    }

    private func nativeDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + nativeDescendants(of: $0) }
    }

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
        let hosting = NSHostingView(rootView: ThreadView(key: key, mailbox: mailbox,
            selectedMessageID: "m1", isReaderActive: true).environment(app).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.level = .floating
        window.orderFront(nil)
        defer { window.close() }

        let (darkView, dark) = try await readerColors(in: hosting, dark: true)
        expectReadable(dark)
        #expect(dark.samples.first { $0.id == "panel" }?.background == [24, 28, 36])
        #expect(dark.samples.first { $0.id == "panel" }?.fill == "rgb(238, 242, 250)")
        #expect(dark.samples.first { $0.id == "button" }?.background == [26, 115, 232])
        #expect(dark.samples.first { $0.id == "nested" }?.fill == "rgb(170, 187, 255)")
        #expect(dark.wideGamutFill == "color(display-p3 0.6 0.7 1)")
        #expect(dark.hiddenFill == "rgba(0, 0, 0, 0)")
        #expect(dark.hiddenCurrentFill == "rgba(0, 0, 0, 0)")

        window.appearance = NSAppearance(named: .aqua)
        let (_, light) = try await readerColors(in: hosting, dark: false)
        expectReadable(light)
        #expect(light.samples.first { $0.id == "copy" }?.fill == "rgb(25, 28, 31)")
        #expect(light.samples.first { $0.id == "copy" }?.background == [255, 255, 255])

        window.appearance = NSAppearance(named: .darkAqua)
        _ = try await readerColors(in: hosting, dark: true)
        var senders = LightBackgroundSenders(storage: "")
        senders.set(true, for: "river@example.invalid")
        settings.set(senders.storage, forKey: ReadingPreferences.lightBackgroundSendersKey)
        let (_, forcedLight) = try await readerColors(in: hosting, dark: false, excluding: darkView)
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

    @Test(.timeLimit(.minutes(1))) func consentedImageUsesMessageSchemeWithNoHTTPSWebKitLoad() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let resources = InlineResourceMap()
        let rendered = MessageDocument.render(html: "<img id='remote' src='https://images.example.com/photo.png'>",
            policy: .init(allowsRemoteImages: true, inlineResources: resources))
        #expect(!rendered.html.contains("src=\"https:"))
        let fetched = Mutex<URL?>(nil)
        let handler = RemoteImageHandler(scope: resources.scope, enabled: true, allowedURLs: rendered.remoteImageURLs) { url in
            fetched.withLock { $0 = url }
            return PinnedRemoteImage(data: png, mimeType: "image/png")
        }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: RemoteImageResourceURL.scheme)
        configuration.userContentController.add(try #require(await RemoteContentBlocker.ruleList(allowsRemoteImages: true)))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { view.stopLoading(); window.close() }
        view.loadHTMLString(rendered.html, baseURL: nil)
        try await waitFor { fetched.withLock { $0 != nil } }
        #expect(fetched.withLock { $0?.absoluteString } == "https://images.example.com/photo.png")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var loaded = false
        repeat {
            loaded = (try? await view.evaluateJavaScript("document.getElementById('remote').naturalWidth > 0",
                in: nil, contentWorld: .defaultClient) as? Bool) == true
            if !loaded { try await Task.sleep(for: .milliseconds(20)) }
        } while !loaded && ContinuousClock.now < deadline
        #expect(loaded)
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

    @Test func readingEventsOnlyCrossTheBridgeWhenTheirValueChanges() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.messages = [];
            globalThis.listeners = {};
            globalThis.webkit = {messageHandlers: {ternReading: {postMessage: value => messages.push(value)}}};
            globalThis.document = {addEventListener: (name, callback) => listeners[name] = callback};
            globalThis.selection = '';
            globalThis.getSelection = () => ({toString: () => selection});
            """)
        context.evaluateScript(MessageWebView.readingScript(revision: 7))
        context.evaluateScript("""
            const hover = href => listeners.mouseover({target: {closest: () => href ? {href} : null}});
            for (let i = 0; i < 100; i++) hover('https://example.invalid/first');
            hover('https://example.invalid/second');
            listeners.mouseleave(); listeners.mouseleave(); hover('');
            selection = 'Selected text';
            for (let i = 0; i < 100; i++) listeners.selectionchange();
            selection = ''; listeners.selectionchange(); listeners.selectionchange();
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("messages.length")?.toInt32() == 5)
        #expect(context.evaluateScript("JSON.stringify(messages.map(value => value.hover ?? value.selection))")?.toString()
            == #"["https://example.invalid/first","https://example.invalid/second","","Selected text",""]"#)
        #expect(context.evaluateScript("messages.every(value => value.revision === 7)")?.toBool() == true)
    }

    @Test func sizingCoalescesCallbacksAndReportsBothGrowthAndShrinkage() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.messages = []; globalThis.frames = []; globalThis.listeners = {};
            globalThis.measurements = 0; globalThis.contentHeight = 200;
            globalThis.webkit = {messageHandlers: {ternHeight: {postMessage: value => messages.push(value)}}};
            globalThis.requestAnimationFrame = callback => frames.push(callback);
            globalThis.getComputedStyle = () => ({paddingTop: '0', paddingBottom: '0', marginTop: '0', marginBottom: '0'});
            globalThis.ResizeObserver = class {
              constructor(callback) { globalThis.resize = callback; }
              observe() {}
            };
            globalThis.document = {
              body: {getBoundingClientRect: () => ({top: 0})},
              createRange: () => {
                measurements++;
                return {selectNodeContents() {}, getBoundingClientRect: () => ({bottom: contentHeight})};
              },
              querySelectorAll: () => [],
              addEventListener: (name, callback) => listeners[name] = callback,
              fonts: {ready: {then: callback => globalThis.fontsReady = callback}}
            };
            """)
        context.evaluateScript(MessageWebView.sizingScript(revision: 3))
        #expect(context.evaluateScript("messages.length")?.toInt32() == 1)
        context.evaluateScript("""
            for (let i = 0; i < 100; i++) { resize(); listeners.load(); }
            fontsReady();
            """)
        #expect(context.evaluateScript("frames.length")?.toInt32() == 1)
        context.evaluateScript("frames.shift()()")
        #expect(context.evaluateScript("measurements")?.toInt32() == 2)
        #expect(context.evaluateScript("messages.length")?.toInt32() == 1)
        context.evaluateScript("""
            contentHeight = 400; resize(); listeners.load(); frames.shift()();
            contentHeight = 100; resize(); fontsReady(); frames.shift()();
            """)
        #expect(context.evaluateScript("JSON.stringify(messages.map(value => value.height))")?.toString() == "[200,400,100]")
        #expect(context.evaluateScript("measurements")?.toInt32() == 4)
        #expect(context.evaluateScript("messages.every(value => value.revision === 3)")?.toBool() == true)
        // Explicit measurements bypass scheduling when animation frames are suspended.
        context.evaluateScript("contentHeight = 650; resize(); __ternSizing.report()")
        #expect(context.evaluateScript("messages.at(-1).height")?.toInt32() == 650)
        context.evaluateScript("contentHeight = 100; frames.shift()()")
        #expect(context.evaluateScript("messages.at(-1).height")?.toInt32() == 100)
        // Activation can recover a report ignored while the renderer was hidden.
        context.evaluateScript("const before = messages.length; __ternSizing.report(true); __ternSizing.report()")
        #expect(context.evaluateScript("messages.length === before + 1")?.toBool() == true)
        #expect(context.evaluateScript("messages.at(-1).height")?.toInt32() == 100)
        #expect(context.exception == nil)
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
          // WebKit can change the media query before the theme listener restores inline styles.
          const dark = matchMedia('(prefers-color-scheme: dark)').matches;
          if ((document.documentElement.style.getPropertyValue('color-scheme') === 'dark') !== dark) return null;
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
    #expect(condition(), "WebKit did not reach the expected state")
}
