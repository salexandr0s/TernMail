import Foundation
import Testing
@testable import MessageContent

@Suite struct ComposeInputTests {
    @Test func mailtoDecodesUnicodeAndLiteralPlusAndOnlySupportedFields() throws {
        let url = try #require(URL(string: "mailto:one+tag@example.com?cc=two%40example.com&bcc=three%40example.com&subject=Gr%C3%BC%C3%9Fe+heute&body=First%0D%0ASecond&from=attacker%40example.com"))
        let parsed = try MailtoParser.parse(url)
        #expect(parsed.to.map(\.address) == ["one+tag@example.com"])
        #expect(parsed.cc.map(\.address) == ["two@example.com"])
        #expect(parsed.bcc.map(\.address) == ["three@example.com"])
        #expect(parsed.subject == "Grüße+heute")
        #expect(parsed.body == "First\nSecond")
    }

    @Test func mailtoRejectsHeaderInjectionAndRepeatedSingletonFields() throws {
        for text in [
            "mailto:one%0D%0Abcc:other@example.com", "mailto:one@example.com?subject=x%0Abcc:other@example.com",
            "mailto:one@example.com?subject=first&subject=second", "https://example.com/"
        ] {
            let url = try #require(URL(string: text))
            #expect(throws: (any Error).self) { try MailtoParser.parse(url) }
        }
        let request = try MailtoParser.parse(#require(URL(string: "mailto:?to=one@example.com&to=ONE@example.com")))
        #expect(request.to.count == 1)
    }

    @Test func markdownConvertsNestedListsEmphasisLinksAndEscapes() {
        let result = MarkdownConverter.document(from: "**Bold** and *soft* [link](https://example.com)\n- First\n    1. Next\n\\*literal\\*")
        #expect(result.blocks[0].runs.contains { $0.text == "Bold" && $0.bold })
        #expect(result.blocks[0].runs.contains { $0.text == "soft" && $0.italic })
        #expect(result.blocks[0].runs.last?.link?.absoluteString == "https://example.com")
        #expect(result.blocks[1].kind == .bulleted(level: 0))
        #expect(result.blocks[2].kind == .numbered(level: 1))
        #expect(result.blocks[3].text == "*literal*")
        #expect(result.blocks[3].runs.allSatisfy { !$0.italic })
    }

    @Test func unsupportedLinksAndUnbalancedMarkersRemainLiteral() {
        let source = "[unsafe](javascript:alert) **unfinished <script>"
        let document = MarkdownConverter.document(from: source)
        #expect(document.plainText() == source)
        #expect(document.blocks.flatMap(\.runs).allSatisfy { $0.link == nil })
        #expect(!document.html().contains("<script>"))
    }

    @Test func inlineImagesRoundTripAndUseRelatedMIMEWithTheirStableCID() throws {
        let image = InlineImageReference(contentID: "image-1@tern.local", altText: "Diagram")
        let document = ComposeDocument(blocks: [.init(runs: [.init("", image: image)])])
        #expect(!document.isEmpty)
        #expect(try JSONDecoder().decode(ComposeDocument.self, from: JSONEncoder().encode(document)) == document)
        #expect(document.html() == "<div><img src=\"cid:image-1@tern.local\" alt=\"Diagram\"></div>")
        #expect(document.plainText() == "Diagram")
        var message = MIMEMessage(from: EmailAddress(address: "me@example.com"))
        message.html = document.html()
        message.attachments = [.init(filename: "image.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: image.contentID)]
        let encoded = String(decoding: message.encoded(), as: UTF8.self)
        #expect(encoded.contains("Content-Type: multipart/related"))
        #expect(encoded.contains("Content-Disposition: inline;"))
        #expect(encoded.contains("Content-ID: <image-1@tern.local>"))
        #expect(!encoded.contains("Content-Type: multipart/mixed"))
        message.attachments.append(.init(filename: "agenda.txt", mimeType: "text/plain", data: Data("Agenda".utf8)))
        #expect(String(decoding: message.encoded(), as: UTF8.self).contains("Content-Type: multipart/mixed"))
    }

    @Test func documentsBeforeInlineSupportDecodeAndCIDHeadersCannotInjectLines() throws {
        let old = Data(#"{"blocks":[{"kind":{"paragraph":{}},"runs":[{"text":"hello","bold":false,"italic":false,"underline":false}]}]}"#.utf8)
        #expect(try JSONDecoder().decode(ComposeDocument.self, from: old).plainText() == "hello")
        var message = MIMEMessage(from: EmailAddress(address: "me@example.com"))
        message.html = "<p>Image</p>"
        message.attachments = [.init(filename: "image.png", mimeType: "image/png", data: Data(), contentID: "bad\r\nBcc: other@example.com")]
        #expect(!String(decoding: message.encoded(), as: UTF8.self).contains("Content-ID:"))
    }
}
