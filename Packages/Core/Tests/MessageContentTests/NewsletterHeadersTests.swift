import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct NewsletterHeadersTests {
    private let link = "https://news.example.com/unsubscribe?token=A%2fb+c%3D"
    private let signature = "v=1; a=rsa-sha256; d=example.com; s=news; h=from:subject:list-unsubscribe:list-unsubscribe-post; b=abcdefgh1234567890=="
    private let verified = "mx.google.com; dkim=pass header.i=@example.com header.s=news header.b=abcdefgh; spf=pass"

    @Test func authenticatedHeaderKeepsOpaqueURLBytesAndReadsFoldedListID() throws {
        let result = try #require(NewsletterHeaders.parse(message([
            ("lIsT-uNsUbScRiBe", " <mailto:leave@example.com?subject=unsubscribe>,\r\n\t<\(link)> "),
            ("LIST-ID", "Weekly news\r\n <weekly.Example.com>"),
        ])))
        #expect(result.webURL?.absoluteString == link)
        #expect(result.oneClickURL?.absoluteString == link)
        #expect(result.mailtoURL?.absoluteString == "mailto:leave@example.com?subject=unsubscribe")
        #expect(result.listID == "weekly.example.com")
    }

    @Test func manualFallbackSurvivesMissingOrFailingAuthentication() throws {
        for authentication in ["", "mx.google.com; dkim=fail header.i=@example.com header.s=news header.b=abcdefgh",
                               "attacker.example.com; dkim=pass header.i=@example.com header.s=news header.b=abcdefgh"] {
            let result = try #require(NewsletterHeaders.parse(message([], authentication: authentication)))
            #expect(result.webURL?.absoluteString == link)
            #expect(result.oneClickURL == nil)
        }
    }

    @Test func neverUsesLaterForgedAuthenticationOrARCPass() throws {
        let forged = try message([
            ("Authentication-Results", verified),
            ("ARC-Authentication-Results", "i=1; " + verified),
        ], authentication: "mx.google.com; dkim=fail")
        #expect(NewsletterHeaders.parse(forged)?.oneClickURL == nil)
        let upstream = try message([("Authentication-Results", verified)], authentication: "other.example.com; dkim=fail")
        #expect(NewsletterHeaders.parse(upstream)?.oneClickURL == nil)
    }

    @Test func passingSignatureMustBeTheOneCoveringBothListHeaders() throws {
        for bad in [
            signature.replacingOccurrences(of: "list-unsubscribe-post", with: "date"),
            signature.replacingOccurrences(of: "d=example.com", with: "d=elsewhere.com"),
            signature.replacingOccurrences(of: "s=news", with: "s=other"),
            signature.replacingOccurrences(of: "b=abcdefgh", with: "b=xxxxxxxx"),
            signature + "; h=list-unsubscribe:list-unsubscribe-post",
        ] {
            #expect(NewsletterHeaders.parse(try message([], signature: bad))?.oneClickURL == nil)
        }
        let noncovering = signature.replacingOccurrences(of: "h=from:subject:list-unsubscribe:list-unsubscribe-post", with: "h=from:subject")
        let forgedCopy = try message([("DKIM-Signature", signature)], signature: noncovering)
        #expect(NewsletterHeaders.parse(forgedCopy)?.oneClickURL == nil)
        let differentCovering = signature.replacingOccurrences(of: "b=abcdefgh", with: "b=xxxxxxxx")
        #expect(NewsletterHeaders.parse(try message([("DKIM-Signature", differentCovering)], signature: noncovering))?.oneClickURL == nil)
    }

    @Test func ambiguousListsAndPostValuesCannotTriggerAutomaticUnsubscribe() throws {
        #expect(NewsletterHeaders.parse(try message([("List-Unsubscribe", "<\(link)>"),
                                                    ("List-Unsubscribe", "<https://other.example.com/leave>")])) == nil)
        for post in ["list-unsubscribe=one-click", "List-Unsubscribe=One-Click&other=value", "List-Unsubscribe=One-Click\nBcc: other"] {
            #expect(NewsletterHeaders.parse(try message([("List-Unsubscribe-Post", post)], post: nil))?.oneClickURL == nil)
        }
        let duplicatePost = try message([("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")])
        #expect(NewsletterHeaders.parse(duplicatePost)?.oneClickURL == nil)
        for second in ["https://other.example.com/leave", "http://127.0.0.1/leave"] {
            #expect(NewsletterHeaders.parse(try message([("List-Unsubscribe", "<\(link)>, <\(second)>")]))?.oneClickURL == nil)
        }
    }

    @Test func malformedListSyntaxAndHeaderInjectionAreRejected() throws {
        for text in [link, "<\(link)>,", "<\(link)><https://other.example.com>", "<<\(link)>>", "<\(link)>\nX-Other: yes"] {
            #expect(NewsletterHeaders.parse(try message([("List-Unsubscribe", text)])) == nil)
        }
    }

    @Test func webURLsExcludePrivateDestinationsCredentialsAndNonWebSchemes() {
        for raw in ["file:///tmp/mail", "javascript:alert(1)", "https://localhost/unsub", "https://127.0.0.1/unsub",
                    "https://[::1]/unsub", "https://0x7f000001/unsub", "https://private.local/unsub",
                    "https://a.internal/unsub", "https://name:secret@example.com/unsub", "https://example.com:8080/unsub",
                    "https://example.com/a%0d%0aHeader:x", "https://example.com/white space", "https://example.com/#leave"] {
            #expect(NewsletterURLPolicy.webURL(raw) == nil)
        }
        #expect(NewsletterURLPolicy.webURL("https://news.example.com/unsub?token=%2f+") != nil)
        #expect(NewsletterURLPolicy.webURL("http://news.example.com/unsub") != nil)
        #expect(NewsletterURLPolicy.webURL("http://news.example.com/unsub", requiresHTTPS: true) == nil)
    }

    @Test func mailtoCannotAddRecipientsOrArbitraryHeaders() {
        for raw in ["mailto:leave@example.com?bcc=other@example.com", "mailto:leave@example.com?to=other@example.com",
                    "mailto:leave@example.com?from=other@example.com", "mailto:leave@example.com,other@example.com",
                    "mailto:leave@example.com?subject=Hi%0aBcc:other@example.com", "mailto:leave@localhost",
                    "mailto:leave@example.com?subject=one&subject=two", "mailto:leave@example.com?attachment=file"] {
            #expect(NewsletterURLPolicy.mailtoURL(raw) == nil)
        }
        #expect(NewsletterURLPolicy.mailtoURL("mailto:leave+token@example.com?subject=Unsubscribe&body=Please%20unsubscribe") != nil)
        #expect(NewsletterURLPolicy.mailtoURL("mailto:leave@example.com?body=Please%20unsubscribe.%0AThank%20you.") != nil)
    }

    private func message(_ fields: [(String, String)], authentication: String? = nil,
                         signature suppliedSignature: String? = nil, post: String? = "List-Unsubscribe=One-Click") throws -> GmailMessage {
        var headers: [(String, String)] = [("Authentication-Results", authentication ?? verified)]
        headers += fields
        if !fields.contains(where: { $0.0.caseInsensitiveCompare("List-Unsubscribe") == .orderedSame }) {
            headers.append(("List-Unsubscribe", "<\(link)>"))
        }
        if let post { headers.append(("List-Unsubscribe-Post", post)) }
        headers.append(("DKIM-Signature", suppliedSignature ?? signature))
        return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: [
            "id": "message", "threadId": "thread", "payload": ["headers": headers.map { ["name": $0.0, "value": $0.1] }],
        ]))
    }
}
