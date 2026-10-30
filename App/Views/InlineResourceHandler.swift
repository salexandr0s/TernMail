import Foundation
import MessageContent
import WebKit

/// The handler owns one immutable message map and performs no file or network I/O.
@MainActor
final class InlineResourceHandler: NSObject, WKURLSchemeHandler {
    let resources: InlineResourceMap
    init(resources: InlineResourceMap) { self.resources = resources }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let resource = resources.resource(for: url) else {
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
