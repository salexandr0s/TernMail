import AppKit
import Foundation
import MailStore
import MessageContent
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ConversationPrintController: NSObject, WKNavigationDelegate {
    private static var active: [UUID: ConversationPrintController] = [:]
    private let id = UUID()
    private let exportsPDF: Bool
    private let completion: (String?) -> Void
    private var webView: WKWebView?

    private init(exportsPDF: Bool, completion: @escaping (String?) -> Void) {
        self.exportsPDF = exportsPDF; self.completion = completion
    }

    static func show(subject: String, messages: [MessageDetail], exportsPDF: Bool = false,
                     completion: @escaping (String?) -> Void) {
        let controller = ConversationPrintController(exportsPDF: exportsPDF, completion: completion)
        active[controller.id] = controller
        let printable = messages.map {
            PrintableMessage(subject: $0.record.subject, sender: $0.record.sender, recipients: $0.record.recipients,
                date: $0.record.date.formatted(date: .abbreviated, time: .shortened),
                body: .init(html: $0.body?.html, plainText: $0.body?.plainText))
        }
        Task {
            guard let blocker = await RemoteContentBlocker.ruleList() else { controller.finish("Printing could not prepare a private message view."); return }
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(blocker)
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
            view.navigationDelegate = controller
            controller.webView = view
            view.loadHTMLString(PrintDocument.render(subject: subject, messages: printable), baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard exportsPDF else {
            let operation = webView.printOperation(with: NSPrintInfo.shared)
            operation.showsPrintPanel = true; operation.showsProgressPanel = true
            _ = operation.run()
            finish(nil)
            return
        }
        let configuration = WKPDFConfiguration()
        webView.createPDF(configuration: configuration) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let data):
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.nameFieldStringValue = "Conversation.pdf"
                    guard panel.runModal() == .OK, let url = panel.url else { self.finish(nil); return }
                    do { try data.write(to: url, options: .atomic); self.finish(nil) }
                    catch { self.finish("The PDF could not be saved.") }
                case .failure: self.finish("The conversation could not be exported as a PDF.")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish("The print view could not be loaded.") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish("The print view could not be loaded.") }

    private func finish(_ message: String?) {
        completion(message)
        webView?.navigationDelegate = nil; webView = nil
        Self.active[id] = nil
    }
}
