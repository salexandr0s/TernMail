import Foundation
import Testing
@testable import MessageContent

@Suite struct MailLinkTests {
    @Test func opaqueAccountAndMessageIDsRoundTripWithoutChangingScope() throws {
        let link = MailLink(accountID: "account+one@example.invalid", threadID: "thread/?&=", messageID: "part+2", partID: "0.2/?&=")
        let url = try #require(link.ternURL)
        #expect(MailLink(url: url) == link)
    }

    @Test func ambiguousOrCredentialBearingReferencesAreRejected() throws {
        for text in [
            "tern://conversation?account=a&account=b&thread=t",
            "tern://conversation?account=a&thread=t&part=1",
            "tern://conversation?account=a&thread=t&message=m&part=1&part=2",
            "tern://conversation?account=a&thread=t&unexpected=1",
            "tern://user@conversation?account=a&thread=t",
            "tern://conversation/other?account=a&thread=t",
            "tern://conversation?account=a&thread=%0A",
            "https://conversation?account=a&thread=t",
            "tern://conversation?account=a"
        ] {
            #expect(MailLink(url: try #require(URL(string: text))) == nil)
        }
    }

    @Test func gmailLinkRoutesByTheAccountAddress() throws {
        let url = try #require(MailLink(accountID: "account", threadID: "thread").gmailURL(email: "a+b@example.invalid"))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "mail.google.com")
        #expect(parts.queryItems == [URLQueryItem(name: "authuser", value: "a+b@example.invalid")])
        #expect(parts.fragment == "all/thread")
    }
}
