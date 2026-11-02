import Foundation
import GmailAPI
import SwiftSoup
import Testing
@testable import MessageContent

@Suite struct ReadingPrivacyTests {
    @Test func readerFindIncludesQuotedRepliesAndTextBeyondTheMailIndexLimit() {
        let html = "<head><style>privateStyle</style></head><p>" + String(repeating: "long message ", count: 10_000)
            + "</p><blockquote>quoted reply needle</blockquote><script>privateScript</script>"
        let prepared = MessageDocument.render(html: html)
        let indexed = MessageDocument.searchableText(.init(html: html))
        for text in [prepared.searchableText, indexed] {
            #expect(text.contains("quoted reply needle"))
            #expect(!text.contains("privateScript"))
            #expect(!text.contains("privateStyle"))
            #expect(text.utf8.count > 100_000)
        }
    }

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
        #expect(try SwiftSoup.parse(blocked.html).select("img[src]").array().allSatisfy { try $0.attr("src").hasPrefix("data:") })
        #expect(!blocked.html.contains("img-src data: tern-message: https:"))
        // Only the HTTPS images would load: not the background, the HTTP image or the trackers.
        #expect(blocked.blockedRemoteImages == 2)
        let allowed = MessageDocument.render(html: html, policy: .init(allowsRemoteImages: true))
        #expect(allowed.html.contains("src=\"https://images.example.com/photo.png\""))
        #expect(try SwiftSoup.parse(allowed.html).select("img[src]").array().map { try $0.attr("src").trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("data:") }
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

    @Test func unavailableImagesKeepLayoutAndAltTextWhileTrackersLeaveNoBlankBox() throws {
        let html = """
        <a href="https://shop.example.com"><img id="photo" src="https://images.example.com/photo.png"
          width="400" height="300" alt="Linen collection" class="hero" style="display:block"></a>
        <img id="logo" src="https://images.example.com/logo.png" width="160" height="80">
        <img id="inline" src="cid:missing" width="120" height="120">
        <img id="tracker" src="https://www.google-analytics.com/collect" width="300" height="200">
        <img id="local" src="data:image/png;base64,AQID" data-tern-image-state="blocked" data-blocked-src="https://fake.example">
        <span id="spoofed" data-tern-image-placeholder data-tern-image-label="Forged label">Keep this text</span>
        """
        let blocked = MessageDocument.render(html: html)
        let document = try SwiftSoup.parse(blocked.html)
        let photo = try #require(try document.getElementById("photo"))
        #expect(try photo.attr("width") == "400")
        #expect(try photo.attr("height") == "300")
        #expect(try photo.attr("alt") == "Linen collection")
        #expect(try photo.attr("title") == "Image blocked")
        #expect(try photo.attr("style") == "display:block")
        #expect(try photo.attr("class") == "hero")
        #expect(try photo.parent()?.attr("href") == "https://shop.example.com")
        #expect(try photo.attr("aria-label") == "Linen collection. Image blocked")
        #expect(!photo.hasAttr("aria-hidden"))
        let svg = try localPlaceholder(photo)
        #expect(svg.contains("width=\"400.0\" height=\"300.0\""))
        #expect(svg.contains("Linen collection"))
        #expect(svg.contains("Image blocked"))
        #expect(svg.contains("prefers-color-scheme:dark"))
        #expect(svg.contains("fill:CanvasText"))
        #expect(try document.getElementById("logo")?.attr("alt") == "Image blocked")
        #expect(try document.getElementById("inline")?.attr("alt") == "Inline image unavailable")
        #expect(try document.getElementById("tracker") == nil)
        #expect(try document.getElementById("local")?.hasAttr("data-tern-image-state") == false)
        #expect(try document.getElementById("local")?.hasAttr("data-blocked-src") == false)
        #expect(try document.getElementById("spoofed")?.hasAttr("data-tern-image-placeholder") == false)
        #expect(try document.getElementById("spoofed")?.hasAttr("data-tern-image-label") == false)
        #expect(blocked.searchableText == "Keep this text")
        #expect(blocked.blockedTrackers == 1)
        #expect(blocked.blockedRemoteImages == 2)

        let allowed = try SwiftSoup.parse(MessageDocument.render(html: html, policy: .init(allowsRemoteImages: true)).html)
        #expect(try allowed.getElementById("photo")?.attr("src") == "https://images.example.com/photo.png")
        #expect(try allowed.getElementById("photo")?.hasAttr("data-tern-image-state") == false)
        #expect(try allowed.getElementById("photo")?.attr("style") == "display:block")
        #expect(try allowed.getElementById("photo")?.parent()?.attr("href") == "https://shop.example.com")
        #expect(try allowed.getElementById("logo")?.hasAttr("alt") == false)
        #expect(try allowed.getElementById("tracker") == nil)
    }

    @Test func unavailableImagesPreserveStylesheetSelectorsAndUseOnlyLocalEscapedSVG() throws {
        let document = try SwiftSoup.parse(MessageDocument.render(html: """
        <style>td > img.hero{width:100%;display:block}</style>
        <table><tr><td><img id="responsive" class="hero" src="cid:missing" width="600" height="240" style="max-width:480px">
        <img id="attribute" class="hero" src="cid:missing" width="50%" height="80"></td></tr></table>
        <img id="escaped" src="cid:missing" width="400" height="300" alt="&lt;script&gt;alert(1)&lt;/script&gt; &amp; quoted">
        <img id="invalid" src="cid:missing" width="100%;background:url(https://images.example.com/fake.png)" height="80">
        """).html)
        let responsive = try #require(try document.getElementById("responsive"))
        #expect(try document.select("td > img.hero").size() == 2)
        #expect(try responsive.attr("style") == "max-width:480px")
        #expect(try localPlaceholder(responsive).contains("width=\"600.0\" height=\"240.0\""))
        #expect(try document.getElementById("attribute")?.attr("width") == "50%")
        let escapedImage = try #require(try document.getElementById("escaped"))
        let escapedSVG = try localPlaceholder(escapedImage)
        #expect(escapedSVG.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(escapedSVG.contains("&amp;"))
        #expect(!escapedSVG.contains("<script"))
        #expect(!escapedSVG.contains("href="))
        #expect(!escapedSVG.contains("<image"))
        #expect(escapedSVG.utf8.count < 4_096)
        let invalidImage = try #require(try document.getElementById("invalid"))
        let invalidSVG = try localPlaceholder(invalidImage)
        #expect(invalidSVG.contains("width=\"300.0\" height=\"80.0\""))
        #expect(!invalidSVG.contains("url("))
        #expect(!invalidSVG.contains("images.example.com"))
    }

    private func localPlaceholder(_ image: Element) throws -> String {
        let source = try image.attr("src")
        let prefix = "data:image/svg+xml;base64,"
        try #require(source.hasPrefix(prefix))
        let bytes = try #require(Data(base64Encoded: String(source.dropFirst(prefix.count))))
        return try #require(String(data: bytes, encoding: .utf8))
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
        #expect(try SwiftSoup.parse(html).select("img[src]").array().allSatisfy { try $0.attr("src").hasPrefix("data:") })
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
