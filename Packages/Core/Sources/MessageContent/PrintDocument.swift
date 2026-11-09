import Foundation
import SwiftSoup

public struct PrintableMessage: Sendable {
    public let subject: String
    public let sender: String
    public let recipients: String
    public let date: String
    public let body: ExtractedBody
    /// The message's cached inline images, from `PrintInlineResources.add`.
    public let inlineResources: InlineResourceMap
    public init(subject: String, sender: String, recipients: String, date: String, body: ExtractedBody,
                inlineResources: InlineResourceMap = .init()) {
        self.subject = subject; self.sender = sender; self.recipients = recipients; self.date = date; self.body = body
        self.inlineResources = inlineResources
    }
}

/// The cached inline images of one print job. Each message keeps its own
/// scope, because two messages can use the same Content-ID. The print view's
/// `tern-message:` handler serves loads from `resource(for:)`, as the reader's does.
public struct PrintInlineResources: Sendable {
    /// A message whose images would pass this total prints without them, so a
    /// long conversation can't hold every image in memory at once.
    public static let maximumBytes = 64 * 1_024 * 1_024
    private var maps: [String: InlineResourceMap] = [:]
    private var byteCount = 0

    public init() {}

    /// Adds one message's cached images, with the reader's limits, and returns
    /// the map to print that message with.
    public mutating func add(_ resources: [InlineMIMEResource]) -> InlineResourceMap {
        let map = InlineResourceMap(resources: resources)
        let bytes = map.resources.values.reduce(0) { $0 + $1.data.count }
        guard !map.resources.isEmpty, byteCount <= Self.maximumBytes - bytes else { return InlineResourceMap() }
        byteCount += bytes
        maps[map.scope] = map
        return map
    }

    public func resource(for url: URL) -> InlineMIMEResource? {
        guard let scope = url.host, let map = maps[scope] else { return nil }
        return map.resource(for: url)
    }
}

public enum PrintDocument {
    /// Printing never loads a sender's remote content, even after an on-screen
    /// opt-in. Inline images come only from each message's cached resources.
    public static func render(subject: String, messages: [PrintableMessage]) -> String {
        let sections = messages.map { message in
            let rendered = MessageDocument.render(message.body, policy: MessageRenderPolicy(inlineResources: message.inlineResources))
            let body: String
            if let rendered, let document = try? SwiftSoup.parse(rendered.html), let content = document.body() {
                // Embedded styles must not recolor the print page or other messages.
                _ = try? content.select("style").remove()
                for element in (try? content.getAllElements().array()) ?? [] {
                    // A lazy image outside the first page could still be loading when the page prints.
                    for name in ["style", "color", "bgcolor", "class", "id", "loading"] { _ = try? element.removeAttr(name) }
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
