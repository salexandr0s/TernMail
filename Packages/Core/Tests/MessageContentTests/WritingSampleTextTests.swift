import Foundation
import Testing
@testable import MessageContent

@Suite struct WritingSampleTextTests {
    @Test func preservesProseAndClosingButRemovesContactDetailsAndSignature() {
        let result = WritingSampleText.extract(html: nil, plainText: """
        Hello there,

        Please send the notes to jane@example.invalid or visit https://example.invalid/private.
        You can reach me at +43 123 456 7890.

        Best regards,
        Jordan Example
        Sales Director
        --
        A repeated company footer.
        """)
        #expect(result.isUsable)
        #expect(result.text.contains("Hello there,\n\nPlease send"))
        #expect(result.text.hasSuffix("Best regards,"))
        #expect(result.text.contains("[email]"))
        #expect(result.text.contains("[link]"))
        #expect(result.text.contains("[number]"))
        #expect(!result.text.contains("example.invalid"))
        #expect(!result.text.contains("Jordan"))
        #expect(!result.truncated)
    }

    @Test func removesHtmlQuotesSignaturesAndHiddenContent() {
        let result = WritingSampleText.extract(html: """
        <head><style>hidden style</style></head><div>Hello team,</div><p>I can review this tomorrow.</p>
        <ul><li>Review notes</li><li>Check details</li></ul>
        <ol start="3"><li>Confirm timing</li><li>Send the update</li></ol>
        <blockquote>Someone else's writing</blockquote><div class="gmail_signature">Jordan, Director</div>
        <script>secret script</script><div class="gmail_quote">Old mail</div>
        """, plainText: nil)
        #expect(result.isUsable)
        #expect(result.text.contains("I can review this tomorrow."))
        #expect(result.text.contains("• Review notes\n• Check details"))
        #expect(result.text.contains("3. Confirm timing\n4. Send the update"))
        #expect(!result.text.contains("Someone"))
        #expect(!result.text.contains("Jordan"))
        #expect(!result.text.contains("script"))
        #expect(!result.text.contains("Old mail"))
    }

    @Test func removesWrappedAttributionAndForwardedHeaders() {
        let reply = WritingSampleText.extract(html: nil, plainText: "I will check this today.\n\nOn Monday,\nJane <jane@example.invalid> wrote:\n> An old message.")
        #expect(reply.text == "I will check this today.")
        let forwarded = WritingSampleText.extract(html: nil, plainText: "Sharing the details below.\nFrom: Someone\nSent: Monday\nTo: Another person\nSubject: An old topic\nForwarded prose.")
        #expect(forwarded.text == "Sharing the details below.")
        let onlyQuote = WritingSampleText.extract(html: nil, plainText: "> Entirely someone else's writing.")
        #expect(!onlyQuote.isUsable)
        #expect(onlyQuote.text.isEmpty)
    }

    @Test func byteLimitPreservesValidUnicodeAndOversizedHtmlIsOmitted() {
        let result = WritingSampleText.extract(html: nil, plainText: String(repeating: "ä", count: 50), maximumBytes: 17)
        #expect(result.text == String(repeating: "ä", count: 8))
        #expect(result.text.utf8.count <= 17)
        #expect(result.truncated)
        let oversized = WritingSampleText.extract(html: String(repeating: "x", count: WritingSampleText.maximumInputBytes + 1), plainText: nil)
        #expect(oversized.text.isEmpty)
        #expect(!oversized.isUsable)
        #expect(oversized.truncated)
    }
}
