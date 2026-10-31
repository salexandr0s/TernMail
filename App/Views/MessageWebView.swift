import AppKit
import MessageContent
import SwiftUI
import WebKit

/// Shows one rendered message. Page scripts are off, every network load is
/// blocked by a content rule list (on top of the page's CSP), web links open
/// in the default browser and mail links stay in Tern, HTML mail follows dark
/// mode, and the view grows to fit its content so the thread scrolls as one page.
struct MessageWebView: NSViewRepresentable {
    let html: String
    let blocker: WKContentRuleList?
    @Binding var height: CGFloat
    var resources = InlineResourceMap()
    var adaptsDarkMode = true
    var forcesLightAppearance = false
    var onHover: (String?) -> Void = { _ in }
    var onSelectionChange: (String) -> Void = { _ in }
    /// `mailto:` and `tern:` links stay in Tern; the app's router opens them.
    var onOpenMailLink: (URL) -> Void = { _ in }
    /// The find bar searches the web views that exist; these report each one.
    var onCreate: (WKWebView) -> Void = { _ in }
    var onDismantle: (WKWebView) -> Void = { _ in }

    /// Where a clicked link goes. Anything but web and mail links is dropped.
    enum LinkAction: Equatable {
        case browser, mail, ignored
    }

    static func linkAction(for url: URL) -> LinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https": .browser
        case "mailto", "tern": .mail
        default: .ignored
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(height: $height, onHover: onHover, onSelectionChange: onSelectionChange, onOpenMailLink: onOpenMailLink)
        coordinator.onDismantle = onDismantle
        return coordinator
    }

    func makeNSView(context: Context) -> ContentSizedWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "ternHeight")
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "ternReading")
        configuration.setURLSchemeHandler(InlineResourceHandler(resources: resources), forURLScheme: InlineResourceMap.scheme)
        configureScripts(configuration.userContentController, revision: 1)
        if let blocker {
            configuration.userContentController.add(blocker)
        }
        let view = ContentSizedWebView(frame: .zero, configuration: configuration)
        MessageWebViewWarmup.messageViewCreated()
        if forcesLightAppearance { view.appearance = NSAppearance(named: .aqua) }
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = false
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.measure(view)
        }
        view.onOpenLink = { [weak coordinator = context.coordinator] url, behind in coordinator?.open(url, behind: behind) }
        context.coordinator.load(html, in: view)
        onCreate(view)
        return view
    }

    func updateNSView(_ view: ContentSizedWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.onHover = onHover
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onOpenMailLink = onOpenMailLink
        context.coordinator.onDismantle = onDismantle
        if context.coordinator.needsLoad(html) {
            view.configuration.userContentController.removeAllContentRuleLists()
            if let blocker { view.configuration.userContentController.add(blocker) }
            configureScripts(view.configuration.userContentController, revision: context.coordinator.nextRevision)
        }
        context.coordinator.load(html, in: view)
    }

    static func dismantleNSView(_ view: ContentSizedWebView, coordinator: Coordinator) {
        coordinator.onDismantle(view)
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ternHeight", contentWorld: .defaultClient)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ternReading", contentWorld: .defaultClient)
        view.navigationDelegate = nil
    }

    private func configureScripts(_ controller: WKUserContentController, revision: Int) {
        controller.removeAllUserScripts()
        if adaptsDarkMode {
            controller.addUserScript(WKUserScript(source: MessageDocument.darkModeScript,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        controller.addUserScript(WKUserScript(source: Self.readingScript(revision: revision),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: Self.sizingScript(revision: revision),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }

    /// Reports text layout as soon as the document exists, before images finish loading.
    static func sizingScript(revision: Int) -> String { """
        (() => {
          if (!document.body) return;
          const measure = () => {
            const body = document.body;
            const range = document.createRange();
            range.selectNodeContents(body);
            const style = getComputedStyle(body);
            const px = value => parseFloat(value) || 0;
            // Content bounds can shrink; the document viewport cannot.
            return Math.ceil(Math.max(px(style.paddingTop),
              range.getBoundingClientRect().bottom - body.getBoundingClientRect().top)
              + px(style.paddingBottom) + px(style.marginTop) + px(style.marginBottom));
          };
          const report = () => {
            webkit.messageHandlers.ternHeight.postMessage({height: measure(), revision: \(revision)});
          };
          const observer = new ResizeObserver(report);
          observer.observe(document.body);
          document.querySelectorAll('img').forEach(image => observer.observe(image));
          document.addEventListener('load', report, true);
          document.fonts.ready.then(report);
          globalThis.__ternSizing = {measure, observer, revision: \(revision)};
          report();
        })()
        """ }

    private static func readingScript(revision: Int) -> String { """
        (() => {
          const send = value => webkit.messageHandlers.ternReading.postMessage({...value, revision: \(revision)});
          document.addEventListener('mouseover', event => {
            const link = event.target.closest?.('a[href]'); send({hover: link?.href ?? ''});
          });
          document.addEventListener('mouseleave', () => send({hover: ''}));
          document.addEventListener('selectionchange', () => {
            send({selection: (getSelection()?.toString() ?? '').slice(0, 100000)});
          });
        })()
        """ }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var onHover: (String?) -> Void
        var onSelectionChange: (String) -> Void
        var onOpenMailLink: (URL) -> Void
        var onDismantle: (WKWebView) -> Void = { _ in }
        private var loadedHTML: String?
        private var revision = 0

        init(height: Binding<CGFloat>, onHover: @escaping (String?) -> Void = { _ in }, onSelectionChange: @escaping (String) -> Void = { _ in },
             onOpenMailLink: @escaping (URL) -> Void = { _ in }) {
            self.height = height
            self.onHover = onHover
            self.onSelectionChange = onSelectionChange
            self.onOpenMailLink = onOpenMailLink
        }

        func needsLoad(_ html: String) -> Bool { html != loadedHTML }
        var nextRevision: Int { revision + 1 }

        func load(_ html: String, in view: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            revision += 1
            let current = revision
            Task { [weak self] in
                guard let self, self.revision == current else { return }
                self.onHover(nil); self.onSelectionChange("")
            }
            view.loadHTMLString(html, baseURL: nil)
        }

        /// Web links go to the default browser, in front of Tern or behind it;
        /// mail links go to Tern's own router.
        func open(_ url: URL, behind: Bool = false) {
            switch MessageWebView.linkAction(for: url) {
            case .browser:
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = !behind
                NSWorkspace.shared.open(url, configuration: configuration)
            case .mail:
                onOpenMailLink(url)
            case .ignored:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                open(url)
                return .cancel
            }
            // Only the page Tern loads itself; refreshes, form posts and frames are refused.
            return url.absoluteString == "about:blank" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
        }

        func measure(_ webView: WKWebView) {
            // Runs in Tern's own script world, which page JavaScript settings don't affect.
            let revision = revision
            let script = """
                globalThis.__ternSizing?.revision === \(revision) ? globalThis.__ternSizing.measure() : 0
                """
            Task { [weak self] in
                guard let value = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient),
                      let self, self.revision == revision,
                      let measured = (value as? NSNumber)?.doubleValue
                else { return }
                acceptHeight(measured)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ternReading", message.frameInfo.isMainFrame,
               let value = message.body as? [String: Any], (value["revision"] as? NSNumber)?.intValue == revision {
                if let hover = value["hover"] as? String {
                    let link = hover.isEmpty ? nil : String(hover.prefix(4_096))
                    (message.webView as? ContentSizedWebView)?.hoveredLink = link.flatMap { URL(string: $0) }
                    onHover(link)
                }
                if let selection = value["selection"] as? String { onSelectionChange(String(selection.prefix(100_000))) }
                return
            }
            guard message.name == "ternHeight", message.frameInfo.isMainFrame,
                  let value = message.body as? [String: Any],
                  (value["revision"] as? NSNumber)?.intValue == revision,
                  let measured = (value["height"] as? NSNumber)?.doubleValue else { return }
            acceptHeight(measured)
        }

        private func acceptHeight(_ measured: Double) {
            guard measured.isFinite, measured > 0 else { return }
            if abs(height.wrappedValue - measured) >= 1 { height.wrappedValue = measured }
        }
    }
}

/// Passes vertical scrolling to the enclosing scroll view, keeps horizontal
/// scrolling for mail wider than the pane, reports width changes, which
/// reflow the message and change its height, and gives links their own
/// context menu.
final class ContentSizedWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    /// The link under the pointer, as the page script reports it.
    var hoveredLink: URL?
    /// Opens a link in front of Tern, or behind it when `behind` is true.
    var onOpenLink: ((_ url: URL, _ behind: Bool) -> Void)?
    private var scrollDirection = ScrollDirection()

    /// WebKit's own link items either navigate this view, which the policy
    /// refuses, or need a UI delegate that makes windows. Tern's take their
    /// place. Reload and history items go too: the page is Tern's own.
    private static let replacedItems: Set<String> = [
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where item.identifier.map({ Self.replacedItems.contains($0.rawValue) }) == true {
            menu.removeItem(item)
        }
        if let hoveredLink {
            var items = [NSMenuItem(title: "Open Link", action: #selector(openLink), keyEquivalent: "")]
            if MessageWebView.linkAction(for: hoveredLink) == .browser {
                items.append(NSMenuItem(title: "Open Link Behind Tern", action: #selector(openLinkBehind), keyEquivalent: ""))
            }
            items.append(NSMenuItem(title: "Copy Link", action: #selector(copyLink), keyEquivalent: ""))
            items.append(.separator())
            for (index, item) in items.enumerated() {
                item.target = self
                menu.insertItem(item, at: index)
            }
        }
        removeStraySeparators(from: menu)
    }

    private func removeStraySeparators(from menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item); continue }
            previousWasSeparator = item.isSeparatorItem
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    @objc private func openLink() {
        if let hoveredLink { onOpenLink?(hoveredLink, false) }
    }

    @objc private func openLinkBehind() {
        if let hoveredLink { onOpenLink?(hoveredLink, true) }
    }

    @objc private func copyLink() {
        guard let hoveredLink else { return }
        NSPasteboard.general.replaceContents(with: hoveredLink.absoluteString)
    }

    override func scrollWheel(with event: NSEvent) {
        let scrollsHorizontally = scrollDirection.isHorizontal(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            startsGesture: event.phase.contains(.began) || event.phase.contains(.mayBegin),
            isMouseWheel: event.phase.isEmpty && event.momentumPhase.isEmpty
        )
        if scrollsHorizontally {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }
}
