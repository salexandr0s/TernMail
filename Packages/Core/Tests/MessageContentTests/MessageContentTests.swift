import Foundation
import GmailAPI
import JavaScriptCore
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
            <div style="background-image: -webkit-image-set('https://t.example/set.png' 1x)">Set</div>
            <svg><style><img src="https://t.example/svg.png"></style></svg>
            <a href=" java&#x09;script:alert(1)" onclick="x()">bad</a>
            <a href="https://example.com/ok">ok</a>
            </body></html>
            """
        let rendered = MessageDocument.render(html: html)
        let page = rendered.html.lowercased()

        for forbidden in ["<script", "refresh", "onload", "onclick", "javascript", "<link", "@import", " src=\"https://", "srcset", "t.example/b.png", "t.example/bg.png", "t.example/set.png", "t.example/svg.png"] {
            #expect(!page.contains(forbidden), "page still contains \(forbidden)")
        }
        #expect(page.contains("data-blocked-src=\"https://t.example/p.gif\""))
        #expect(page.contains("src=\"data:image/png;base64,aaaa\""))
        #expect(page.contains("url(#g)"))
        #expect(page.contains("href=\"https://example.com/ok\""))
        #expect(rendered.html.contains(MessageDocument.contentSecurityPolicy))
        // The stylesheet link, @import, style-block url(), the remote img and the two inline styles.
        #expect(rendered.blockedRemoteContent == 6)
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
              ,{"mimeType":"multipart/mixed","headers":[{"name":"Content-Disposition","value":"attachment"}],
                "parts":[{"mimeType":"text/plain","body":{"data":"\(base64URL(Data("attached multipart".utf8)))"}}]}
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

    @Test func darkModeKeepsCommonMailColorsReadable() throws {
        let context = try #require(JSContext())
        let palette = try #require(context.evaluateScript(MessageDocument.darkModeScript))
        let colors = try #require(palette.call(withArguments: [[30, 30, 30], [255, 255, 255]]))
        func adapt(_ method: String, _ arguments: [Any]) -> [Int] {
            colors.invokeMethod(method, withArguments: arguments).toArray() as? [Int] ?? []
        }

        let page = adapt("background", [[255, 255, 255]])
        #expect(zip(page, [30, 30, 30]).allSatisfy { abs($0 - $1) <= 1 }, "white became \(page)")
        #expect(adapt("background", [[26, 115, 232]]) == [26, 115, 232], "a saturated button keeps its color")

        // Text over background: body text, muted text, a link, a highlight, a button label.
        let pairs = [
            ([0, 0, 0], [255, 255, 255]), ([51, 51, 51], [244, 244, 244]), ([102, 102, 102], [255, 255, 255]),
            ([17, 85, 204], [255, 255, 255]), ([0, 0, 0], [255, 255, 0]), ([255, 255, 255], [26, 115, 232]),
        ]
        for (text, background) in pairs {
            let darkBackground = adapt("background", [background])
            let darkText = adapt("text", [text, 1, darkBackground])
            let ratio = colors.invokeMethod("contrast", withArguments: [darkText, darkBackground]).toDouble()
            #expect(ratio >= 4.5, "\(text) on \(background) became \(darkText) on \(darkBackground)")
        }
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
