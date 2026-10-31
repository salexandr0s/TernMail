import WebKit

/// Starts WebKit before the first message opens, using an empty private page.
@MainActor
enum MessageWebViewWarmup {
    private static var hasStarted = false
    private static var view: WKWebView?

    static func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let warming = WKWebView(frame: .zero, configuration: configuration)
        view = warming
        warming.loadHTMLString("""
            <!doctype html><html><head>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'">
            </head><body></body></html>
            """, baseURL: nil)
    }

    static func messageViewCreated() {
        // Message views keep their own data stores; only WebKit startup is shared.
        hasStarted = true
        view?.stopLoading()
        view = nil
    }
}
