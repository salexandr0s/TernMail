import Foundation
import SwiftSoup

public struct PrintableMessage: Sendable {
    public let subject: String
    public let sender: String
    public let recipients: String
    public let date: String
    public let body: ExtractedBody
    public init(subject: String, sender: String, recipients: String, date: String, body: ExtractedBody) {
        self.subject = subject; self.sender = sender; self.recipients = recipients; self.date = date; self.body = body
    }
}

public enum PrintDocument {
    /// Printing never loads a sender's remote content, even after an on-screen opt-in.
    public static func render(subject: String, messages: [PrintableMessage]) -> String {
        let sections = messages.map { message in
            let rendered = MessageDocument.render(message.body)
            let body: String
            if let rendered, let document = try? SwiftSoup.parse(rendered.html), let content = document.body() {
                // Embedded styles must not recolor the print page or other messages.
                try? content.select("style").remove()
                for element in (try? content.getAllElements().array()) ?? [] {
                    for name in ["style", "color", "bgcolor", "class", "id"] { try? element.removeAttr(name) }
                }
                body = (try? content.html()) ?? ""
            } else { body = "" }
            return "<section><h2>\(MessageDocument.escaped(message.subject))</h2>"
                + "<p>\(MessageDocument.escaped(message.sender))<br>\(MessageDocument.escaped(message.recipients))<br>\(MessageDocument.escaped(message.date))</p>"
                + "<div class=\"message\">\(body)</div></section>"
        }.joined()
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(MessageDocument.contentSecurityPolicy)\">"
            + "<title>\(MessageDocument.escaped(subject))</title><style>body{font:12pt -apple-system;color:#000;background:#fff}section{break-inside:auto;margin-bottom:24pt}h2{font-size:14pt}p{font-size:10pt;color:#444}.message{overflow-wrap:anywhere}img{max-width:100%}</style>"
            + "</head><body><h1>\(MessageDocument.escaped(subject))</h1>\(sections)</body></html>"
    }
}
