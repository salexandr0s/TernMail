import Foundation
import MessageContent
import WebKit

/// The handler serves one message's map and performs no file or network I/O.
/// A spare view's handler has no map and serves nothing. It takes a map once,
/// when a message gets the view, and that map never changes afterwards.
@MainActor
final class InlineResourceHandler: NSObject, WKURLSchemeHandler {
    private(set) var resources: InlineResourceMap?
    init(resources: InlineResourceMap? = nil) { self.resources = resources }

    /// Gives a handler without a map its message's map. A handler that has
    /// one keeps it, so a view can never start serving another message.
    func assign(_ resources: InlineResourceMap) {
        guard self.resources == nil else { return }
        self.resources = resources
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let resource = resources?.resource(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: resource.mimeType,
            expectedContentLength: resource.data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(resource.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
