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

    static func show(subject: String, messages: [MessageDetail], exportsPDF: Bool = false,
                     completion: @escaping (String?) -> Void) {
        let controller = ConversationPrintController(subject: subject, exportsPDF: exportsPDF, window: NSApp.keyWindow, completion: completion)
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
