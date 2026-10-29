import AppKit
import SwiftUI
import WebKit

/// Shows one rendered message. Page scripts are off, every network load is
/// blocked by a content rule list (on top of the page's CSP), links open in
/// the default browser, and the view grows to fit its content so the thread
/// scrolls as one page.
struct MessageWebView: NSViewRepresentable {
    let html: String
    let blocker: WKContentRuleList?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> ContentSizedWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "ternHeight")
        if let blocker {
            configuration.userContentController.add(blocker)
        }
        let view = ContentSizedWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = false
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.measure(view)
        }
        context.coordinator.load(html, in: view)
        return view
    }

    func updateNSView(_ view: ContentSizedWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.load(html, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        private var loadedHTML: String?
        private var revision = 0

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func load(_ html: String, in view: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            revision += 1
            view.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
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
                (() => {
                  if (!document.body) return 0;
                  if (typeof globalThis.__ternSizing?.measure !== 'function') {
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
                    globalThis.__ternSizing = {measure, observer};
                  }
                  return globalThis.__ternSizing.measure();
                })()
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
            guard let value = message.body as? [String: Any],
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
/// scrolling for mail wider than the pane, and reports width changes, which
/// reflow the message and change its height.
final class ContentSizedWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var scrollDirection = ScrollDirection()

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

/// A trackpad may begin with zero deltas. Choose its axis on the first actual
/// movement and keep it through momentum; a mouse wheel decides per event.
struct ScrollDirection {
    private var horizontal: Bool?

    mutating func isHorizontal(x: CGFloat, y: CGFloat, startsGesture: Bool = false, isMouseWheel: Bool = false) -> Bool {
        if startsGesture || isMouseWheel { horizontal = nil }
        if horizontal == nil, x != 0 || y != 0 { horizontal = abs(x) > abs(y) }
        return horizontal ?? false
    }
}

/// Compiles, once, the rule list that blocks every load except inline data.
/// Rule regexes don't support alternation, so each allowed scheme has its own rule.
@MainActor
enum RemoteContentBlocker {
    private static var cached: WKContentRuleList?
    private static let rules = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^cid:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """

    static func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        guard let store = WKContentRuleListStore.default() else { return nil }
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<RuleListBox, Never>) in
            store.compileContentRuleList(forIdentifier: "TernBlockRemoteContent", encodedContentRuleList: rules) { list, _ in
                continuation.resume(returning: RuleListBox(list: list))
            }
        }
        cached = box.list
        return box.list
    }
}

/// Carries the compiled list out of WebKit's completion handler, which runs on
/// the main thread, back to the main actor that asked for it.
private struct RuleListBox: @unchecked Sendable {
    let list: WKContentRuleList?
}
