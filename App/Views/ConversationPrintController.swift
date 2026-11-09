import AppKit
import Foundation
import MailStore
import MessageContent
import UniformTypeIdentifiers
import WebKit

/// Lays the conversation out in a private web view at the printer's paper
/// size, then runs the print or save panel as a sheet on the window that asked.
@MainActor
final class ConversationPrintController: NSObject, WKNavigationDelegate {
    private static var active: [UUID: ConversationPrintController] = [:]
    private let id = UUID()
    private let subject: String
    private let exportsPDF: Bool
    private let completion: (String?) -> Void
    private weak var window: NSWindow?
    private var webView: WKWebView?

    private init(subject: String, exportsPDF: Bool, window: NSWindow?, completion: @escaping (String?) -> Void) {
        self.subject = subject; self.exportsPDF = exportsPDF; self.window = window; self.completion = completion
    }

    static func show(subject: String, messages: [MessageDetail], cache: MailCache, exportsPDF: Bool = false,
                     completion: @escaping (String?) -> Void) {
        let controller = ConversationPrintController(subject: subject, exportsPDF: exportsPDF, window: NSApp.keyWindow, completion: completion)
        active[controller.id] = controller
        Task {
            guard let blocker = await RemoteContentBlocker.ruleList() else { controller.finish("Printing could not prepare a private message view."); return }
            // Inline images come from the cache the reader fills when a message
            // opens. Printing fetches nothing, so an unopened message's images stay unavailable.
            var resources = PrintInlineResources()
            var printable: [PrintableMessage] = []
            for message in messages {
                let records = (try? await cache.mimeResources(messageID: message.id, accountID: message.record.accountID)) ?? []
                let inline = resources.add(records.map {
                    InlineMIMEResource(contentID: $0.contentID, partID: $0.partID, mimeType: $0.mimeType, data: $0.data)
                })
                printable.append(PrintableMessage(subject: message.record.subject, sender: message.record.sender,
                    recipients: message.record.recipients, date: message.record.date.formatted(date: .abbreviated, time: .shortened),
                    body: .init(html: message.body?.html, plainText: message.body?.plainText), inlineResources: inline))
            }
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(blocker)
            configuration.setURLSchemeHandler(PrintResourceHandler(resources: resources), forURLScheme: InlineResourceMap.scheme)
            let view = WKWebView(frame: NSRect(origin: .zero, size: NSPrintInfo.shared.paperSize), configuration: configuration)
            view.navigationDelegate = controller
            controller.webView = view
            view.loadHTMLString(PrintDocument.render(subject: subject, messages: printable), baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if exportsPDF {
            Task { await exportPDF(from: webView) }
            return
        }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        guard let window else {
            _ = operation.run()
            finish(nil)
            return
        }
        operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish(nil)
    }

    private func exportPDF(from webView: WKWebView) async {
        let data: Data
        do { data = try await webView.pdf(configuration: WKPDFConfiguration()) }
        catch { finish("The conversation could not be exported as a PDF."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = AttachmentFileExport.safeFilename(subject.isEmpty ? "Conversation" : subject) + ".pdf"
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { finish(nil); return }
        do { try data.write(to: url, options: .atomic); finish(nil) }
        catch { finish("The PDF could not be saved.") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish("The print view could not be loaded.") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish("The print view could not be loaded.") }

    private func finish(_ message: String?) {
        completion(message)
        webView?.navigationDelegate = nil; webView = nil
        Self.active[id] = nil
    }
}

/// Serves a print job's cached inline images from memory. Like the reader's
/// `InlineResourceHandler`, it performs no file or network I/O, but it answers
/// for every message in the job, each under its own scope.
@MainActor
private final class PrintResourceHandler: NSObject, WKURLSchemeHandler {
    private let resources: PrintInlineResources
    init(resources: PrintInlineResources) { self.resources = resources }

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
