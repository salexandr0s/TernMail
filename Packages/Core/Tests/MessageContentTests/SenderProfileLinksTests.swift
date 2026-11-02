import Foundation
import Testing
@testable import MessageContent

@Suite struct SenderProfileLinksTests {
    @Test func extractsPlainSignaturesAndDeduplicatesTrackingVariants() {
        let result = SenderProfileLinks.extract(plainText: """
        Please read https://news.example.com/article before tomorrow.

        Best regards,
        Jane Example
        https://www.linkedin.com/in/jane-example/?utm_source=email
        https://linkedin.com/in/jane-example
        Website: www.example.com
        """, html: nil)
        #expect(result.map(\.kind) == [.linkedin, .website])
        #expect(result.map(\.url.absoluteString) == ["https://linkedin.com/in/jane-example", "https://example.com"])
    }

    @Test func retainsIconOnlyHtmlLinksButDiscardsQuotedAndForwardedSignatures() {
        let result = SenderProfileLinks.extract(plainText: nil, html: """
        <p>Please read <a href="https://example.com/article">the article</a>.</p>
        <div class="gmail_signature">Jane<br><a href="https://instagram.com/jane.example?igsh=abc"><img src="icon.png"></a>
        <a href="https://github.com/jane-example">GitHub</a></div>
        <blockquote><div class="gmail_signature"><a href="https://linkedin.com/in/other-person">Other</a></div></blockquote>
        <div id="divRplyFwdMsg">From: Another person</div>
        <div class="gmail_signature"><a href="https://example.org">Old signature</a></div>
        """)
        #expect(result.map(\.kind) == [.instagram, .github])
        #expect(result.first?.url.absoluteString == "https://instagram.com/jane.example")
        let forwardOnly = SenderProfileLinks.extract(plainText: nil, html: """
        <p>Forwarding this.</p><div id="divRplyFwdMsg">From: Another person</div>
        <div class="gmail_signature"><a href="https://example.org">Old signature</a></div>
        """)
        #expect(forwardOnly.isEmpty)
    }

    @Test func rejectsUnsafeAndActionURLs() {
        let result = SenderProfileLinks.extract(plainText: nil, html: """
        <div class="gmail_signature">
        <a href="javascript:alert(1)">script</a><a href="file:///etc/hosts">file</a>
        <a href="javascript:void(0)">https://example.com</a>
        <a href="https://user:password@example.com">credentials</a>
        <a href="https://127.0.0.1">loopback</a><a href="https://10.0.0.1">private</a>
        <a href="https://[::1]">v6</a><a href="https://printer.local">local</a>
        <a href="https://example.com:8080">port</a><a href="https://example.com/unsubscribe?id=123">unsubscribe</a>
        <a href="https://click.example.com/person">tracking</a><a href="https://example.com/?redirect=https://github.com/a">redirect</a>
        <a href="https://linkedin.com">home</a><a href="https://instagram.com/p/123">post</a>
        <a href="https://twitter.com/intent/tweet">share</a><a href="https://github.com/a/repository">repository</a>
        </div>
        """)
        #expect(result.isEmpty)
    }

    @Test func recognizesOutlookIconOnlySignature() {
        let result = SenderProfileLinks.extract(plainText: nil, html: """
        <p>The proposal is attached.</p>
        <div id="Signature">Jane Example<br><a href="https://linkedin.com/in/jane"><img src="linkedin.png"></a></div>
        <div id="divRplyFwdMsg">From: Someone else</div>
        <div id="Signature"><a href="https://linkedin.com/in/other"><img src="linkedin.png"></a></div>
        """)
        #expect(result.map(\.url.absoluteString) == ["https://linkedin.com/in/jane"])
    }

    @Test func requiresClosingSignOffBeforeContactDetails() {
        let openingThanks = "Thanks,\n\nI found the author here:\nhttps://linkedin.com/in/someone-else\n\nCould you review their proposal?"
        #expect(SenderProfileLinks.extract(plainText: openingThanks, html: nil).isEmpty)
        let continuedProse = "The proposal is attached.\n\nThanks,\nJane\nhttps://linkedin.com/in/jane\n\nCould you review their proposal?"
        #expect(SenderProfileLinks.extract(plainText: continuedProse, html: nil).isEmpty)
        let closingThanks = "The proposal is attached.\n\nThanks,\nWill Example\nhttps://linkedin.com/in/will"
        #expect(SenderProfileLinks.extract(plainText: closingThanks, html: nil).map(\.url.absoluteString) == ["https://linkedin.com/in/will"])
    }

    @Test func ignoresBodyArticlesAndOtherPeoplesPlainSignatures() {
        #expect(SenderProfileLinks.extract(plainText: "Please read https://example.com/article.\nhttps://linkedin.com/in/author", html: nil).isEmpty)
        #expect(SenderProfileLinks.extract(plainText: "--\nEmail: jane@www.example.com", html: nil).isEmpty)
        #expect(SenderProfileLinks.extract(plainText: """
        I agree.

        On Monday,
        Jane wrote:
        Best regards,
        Jane
        https://linkedin.com/in/jane
        """, html: nil).isEmpty)
        #expect(SenderProfileLinks.extract(plainText: "I agree.\n> --\n> https://example.com", html: nil).isEmpty)
        #expect(SenderProfileLinks.extract(plainText: "Forwarding this.\nFrom: Jane\nTo: Alex\n--\nhttps://example.com", html: nil).isEmpty)
    }

    @Test func supportsLabelledContactFooterAndKnownPlatforms() {
        let result = SenderProfileLinks.extract(plainText: """
        The details are attached.

        Jane Example
        Website: https://example.com
        https://x.com/jane_example
        https://youtube.com/@jane
        https://tiktok.com/@jane
        https://mastodon.social/@jane
        https://facebook.com/profile.php?id=12345&utm_medium=email
        """, html: nil)
        #expect(result.map(\.kind) == [.website, .x, .youtube, .tiktok, .mastodon, .facebook])
        #expect(result.last?.url.query == "id=12345")
    }

    @Test func boundsUntrustedInputsAndOutput() {
        #expect(SenderProfileLinks.extract(plainText: String(repeating: "x", count: SenderProfileLinks.maximumInputBytes) + "\n--\nhttps://example.com", html: nil).isEmpty)
        let many = (1...50).map { "https://example\($0).com" }.joined(separator: "\n")
        #expect(SenderProfileLinks.extract(plainText: "--\n" + many, html: nil).count == 12)
    }
}
