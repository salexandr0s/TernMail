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
    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        private var loadedHTML: String?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func load(_ html: String, in view: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
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
            let script = """
                Math.ceil(Math.max(
                  document.documentElement.getBoundingClientRect().height,
                  document.body ? document.body.scrollHeight : 0
                ))
                """
            Task { [height] in
                guard let value = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient),
                      let measured = (value as? NSNumber)?.doubleValue,
                      measured > 0
                else { return }
                if abs(height.wrappedValue - measured) >= 1 {
                    height.wrappedValue = measured
                }
            }
        }
    }
}

/// Passes scroll events to the enclosing scroll view and reports width
/// changes, which reflow the message and change its height.
final class ContentSizedWebView: WKWebView {
    var onWidthChange: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
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
