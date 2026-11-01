import Foundation
import GmailAPI
import SwiftSoup
import Testing
@testable import MessageContent

@Suite struct ReadingPrivacyTests {
    @Test func remoteImageConsentAllowsOnlyHTTPSAndKeepsTrackersBlocked() throws {
        let html = """
        <style>.x{background:url(https://images.example.com/background.png)}</style>
        <img src="https://images.example.com/photo.png" width="200" height="100">
        <img src=" https://images.example.com/padded.png">
        <img src="http://images.example.com/insecure.png">
        <img src="https://www.google-analytics.com/collect">
        <img src="https://other.example.com/open.png" style="width:1px;height:1px!important">
        <img srcset="https://other.example.com/more.png 2x"><script>alert(1)</script>
        """
        let blocked = MessageDocument.render(html: html)
        #expect(try SwiftSoup.parse(blocked.html).select("img[src]").isEmpty())
        #expect(!blocked.html.contains("img-src data: tern-message: https:"))
        // Only the HTTPS images would load: not the background, the HTTP image or the trackers.
        #expect(blocked.blockedRemoteImages == 2)
        let allowed = MessageDocument.render(html: html, policy: .init(allowsRemoteImages: true))
        #expect(allowed.html.contains("src=\"https://images.example.com/photo.png\""))
        #expect(try SwiftSoup.parse(allowed.html).select("img[src]").array().map { try $0.attr("src").trimmingCharacters(in: .whitespaces) }
            == ["https://images.example.com/photo.png", "https://images.example.com/padded.png"])
        #expect(!allowed.html.contains("google-analytics.com"))
        #expect(!allowed.html.contains("open.png"))
        #expect(!allowed.html.contains("srcset"))
        #expect(!allowed.html.contains("background.png"))
        #expect(!allowed.html.contains("<script"))
        #expect(allowed.blockedTrackers == 2)
        #expect(allowed.blockedRemoteImages == 0)
        #expect(allowed.html.contains("img-src data: tern-message: https:"))
        #expect(!TrackerMatcher.matches(URL(string: "https://google-analytics.com.attacker.example/photo.png")!))
    }

    @Test func inlineResourceURLsAreImmutableAndCannotCrossMessageScopes() throws {
        let image = InlineMIMEResource(contentID: "Logo@Example", partID: "1", mimeType: "image/png", data: Data([1, 2, 3]))
        let first = InlineResourceMap(resources: [image])
        let second = InlineResourceMap(resources: [image])
        let url = try #require(first.url(for: "<Logo@Example>"))
        #expect(first.resource(for: url) == image)
        #expect(second.resource(for: url) == nil)
        #expect(first.url(for: "logo@example") == nil)
        #expect(first.resource(for: URL(string: url.absoluteString + "?other=message")!) == nil)
        #expect(first.resource(for: URL(string: "tern-message://\(first.scope)/../secret")!) == nil)
        let rendered = MessageDocument.render(html: "<img src=\"cid:Logo%40Example\"><img src=\"cid:unknown\">",
            policy: .init(inlineResources: first))
        #expect(rendered.html.contains(url.absoluteString))
        #expect(!rendered.html.contains("cid:"))
        #expect(!rendered.html.contains("unknown"))
    }

    @Test func inlinePartSelectionSkipsAttachedMessagesUnsupportedImagesAndOversizedResources() throws {
        let json = #"""
        {"id":"m","threadId":"t","payload":{"mimeType":"multipart/related","parts":[
          {"partId":"1","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<good>"}],"body":{"size":3,"data":"AQID"}},
          {"partId":"2","mimeType":"image/svg+xml","headers":[{"name":"Content-ID","value":"<svg>"}],"body":{"size":3,"data":"AQID"}},
          {"partId":"3","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<huge>"}],"body":{"size":5242881,"attachmentId":"skip"}},
          {"mimeType":"message/rfc822","parts":[{"partId":"4","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<foreign>"}],"body":{"size":3,"data":"AQID"}}]}
        ]}}
        """#
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        let parts = InlineMIMEResources.parts(of: message)
        #expect(parts.map(\.contentID) == ["good"])
        #expect(parts.first?.inlineData == Data([1, 2, 3]))
        #expect(InlineMIMEResources.normalizedContentID("bad\r\nvalue") == nil)
    }

    @Test func printingSanitizesEveryBodyAndEscapesMetadata() throws {
        let html = PrintDocument.render(subject: "<script>subject</script>", messages: [
            .init(subject: "Meeting", sender: "<img src=https://bad.example>", recipients: "a@example.com", date: "Today",
                body: .init(html: "<script>alert(1)</script><p>Hello</p><img src=https://bad.example/pixel.png>"))
        ])
        #expect(!html.contains("<script"))
        #expect(try SwiftSoup.parse(html).select("img[src]").isEmpty())
        #expect(html.contains("&lt;script&gt;subject&lt;/script&gt;"))
        #expect(html.contains("<p>Hello</p>"))
    }

    @Test func authoredDarkStylesAndTextScaleSurviveSafeRendering() {
        let rendered = MessageDocument.render(html: "<style>@media(prefers-color-scheme: dark){body{color:white;background:black}}</style><p>Hello</p>",
            policy: .init(textScale: 1.5))
        #expect(rendered.html.contains("prefers-color-scheme"))
        #expect(rendered.html.contains("font-size:19.5px"))
        #expect(MessageRenderPolicy(textScale: .infinity).textScale == 1)
    }
}
