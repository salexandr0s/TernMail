import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct MessageContentTests {
    @Test func sanitizerRemovesActiveContentAndRemoteLoads() {
        let html = """
            <html><head>
            <meta http-equiv="refresh" content="0;url=https://evil.example/">
            <link rel="stylesheet" href="https://t.example/s.css">
            <style>@import url(https://t.example/a.css); .x{background:url("https://t.example/b.png")} .y{fill:url(#g)}</style>
            </head><body>
            <script>alert(1)</script>
            <img src="https://t.example/p.gif" srcset="https://t.example/p2.gif 2x" onload="x()">
            <img src="data:image/png;base64,AAAA">
            <div style="background-image: url('https://t.example/bg.png')">Hi</div>
            <a href=" java&#x09;script:alert(1)" onclick="x()">bad</a>
            <a href="https://example.com/ok">ok</a>
            </body></html>
            """
        let rendered = MessageDocument.render(html: html)
        let page = rendered.html.lowercased()

        for forbidden in ["<script", "refresh", "onload", "onclick", "javascript", "<link", "@import", " src=\"https://", "srcset", "t.example/b.png", "t.example/bg.png"] {
            #expect(!page.contains(forbidden), "page still contains \(forbidden)")
        }
        #expect(page.contains("data-blocked-src=\"https://t.example/p.gif\""))
        #expect(page.contains("src=\"data:image/png;base64,aaaa\""))
        #expect(page.contains("url(#g)"))
        #expect(page.contains("href=\"https://example.com/ok\""))
        #expect(rendered.html.contains(MessageDocument.contentSecurityPolicy))
        // The stylesheet link, @import, style-block url(), the remote img and the inline style.
        #expect(rendered.blockedRemoteContent == 5)
    }

    @Test func extractsTextPartsInTheirDeclaredCharsetAndSkipsAttachments() throws {
        let latin1 = try #require("Café au lait".data(using: .isoLatin1))
        let json = """
            {"id":"m1","threadId":"t1","payload":{"mimeType":"multipart/mixed","parts":[
              {"mimeType":"multipart/alternative","parts":[
                {"mimeType":"text/plain","headers":[{"name":"Content-Type","value":"text/plain; charset=\\"ISO-8859-1\\""}],
                 "body":{"data":"\(base64URL(latin1))"}},
                {"mimeType":"text/html","headers":[{"name":"Content-Type","value":"text/html; charset=utf-8"}],
                 "body":{"data":"\(base64URL(Data("<p>Café</p>".utf8)))"}}
              ]},
              {"mimeType":"text/plain","filename":"notes.txt","body":{"data":"\(base64URL(Data("attached".utf8)))"}}
            ]}}
            """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        let body = MIMEParts.body(of: message)

        #expect(body.plainText == "Café au lait")
        #expect(body.html == "<p>Café</p>")
    }

    @Test func plainTextIsEscapedAndLinked() {
        let page = MessageDocument.render(plainText: "<b>hi</b> see https://example.com/a?b=1&c=2").html

        #expect(page.contains("&lt;b&gt;hi&lt;/b&gt;"))
        #expect(page.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">https://example.com/a?b=1&amp;c=2</a>"))
        #expect(HTMLEntities.decode("Tom&#39;s &amp; Jerry") == "Tom's & Jerry")
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
