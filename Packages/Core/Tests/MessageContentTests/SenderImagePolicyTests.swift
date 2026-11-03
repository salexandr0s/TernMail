import Foundation
import GmailAPI
import Testing
@testable import MessageContent

@Suite struct SenderImagePolicyTests {
    private let pass = "mx.google.com; dkim=pass header.i=@example.com; dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=example.com"

    @Test func rememberedSenderRequiresAlignedGmailReceiverDMARC() throws {
        let verified = try message(authentication: pass)
        #expect(SenderImagePolicy.verifiedSender(in: verified) == "trusted@example.com")
        let folded = pass.replacingOccurrences(of: "; ", with: ";\r\n\t")
        #expect(SenderImagePolicy.verifiedSender(in: try message(authentication: folded)) == "trusted@example.com")
        for authentication in [nil, "mx.google.com; dmarc=fail header.from=example.com",
                               "mx.google.com; dkim=pass header.i=@attacker.net; spf=pass smtp.mailfrom=attacker.net",
                               "mx.google.com; dmarc=pass header.from=attacker.net",
                               "other.example.net; dmarc=pass header.from=example.com"] {
            #expect(SenderImagePolicy.verifiedSender(in: try message(authentication: authentication)) == nil)
        }
    }

    @Test func laterForgedResultsAndARCDoNotOverrideTheReceiver() throws {
        for first in [nil, "mx.google.com; dmarc=fail header.from=example.com",
                      "untrusted.example.net; dmarc=pass header.from=example.com"] {
            var extra = [("ARC-Authentication-Results", "i=1; " + pass)]
            if first != nil { extra.append(("Authentication-Results", pass)) }
            #expect(SenderImagePolicy.verifiedSender(in: try message(authentication: first, extra: extra)) == nil)
        }
    }

    @Test func ambiguousOrMalformedEvidenceCannotGrantSenderTrust() throws {
        for authentication in [pass + "; dmarc=fail header.from=example.com",
                               pass + "; dmarc = fail header.from=example.com",
                               pass + "; dmarc/1=fail header.from=example.com",
                               pass + " header.from=example.com",
                               "mx.google.com; dmarc=pass (unclosed header.from=example.com",
                               "mx.google.com; dmarc=pass header.from=example.com\nX-Forged: yes"] {
            #expect(SenderImagePolicy.verifiedSender(in: try message(authentication: authentication)) == nil)
        }
        #expect(SenderImagePolicy.verifiedSender(in: try message(authentication: pass,
            from: "trusted@example.com, other@example.com")) == nil)
        #expect(SenderImagePolicy.verifiedSender(in: try message(authentication: pass,
            extra: [("From", "other@example.com")])) == nil)
    }

    @Test func permissionCannotSurviveChangedIdentityOrReceiverEvidence() {
        let granted = identity()
        #expect(granted.permitsRemembered(granted))
        for changed in [identity(account: "other-account"), identity(message: "other-message"),
                        identity(from: "Other <other@example.com>"), identity(evidence: nil),
                        identity(evidence: "other@example.com")] {
            #expect(!changed.permitsRemembered(granted))
            #expect(!changed.allowsImages(blocksRemoteImages: true, explicit: nil, remembered: granted))
            #expect(!changed.allowsImages(blocksRemoteImages: true, explicit: granted, remembered: nil))
        }
    }

    @Test func explicitMessageAndGlobalConsentRemainAvailableForUnverifiedSenders() {
        let unverified = identity(evidence: nil)
        #expect(!unverified.permitsRemembered(unverified))
        #expect(!unverified.allowsImages(blocksRemoteImages: true, explicit: nil, remembered: unverified))
        #expect(unverified.allowsImages(blocksRemoteImages: true, explicit: unverified, remembered: nil))
        #expect(unverified.allowsImages(blocksRemoteImages: false, explicit: nil, remembered: nil))
    }

    private func identity(account: String = "account", message: String = "message",
                          from: String = "Trusted <trusted@example.com>", evidence: String? = "trusted@example.com") -> SenderImageIdentity {
        SenderImageIdentity(accountID: account, messageID: message, from: from, verifiedSender: evidence)
    }

    private func message(authentication: String?, from: String = "Trusted <trusted@example.com>",
                         extra: [(String, String)] = []) throws -> GmailMessage {
        var headers = [["name": "From", "value": from]]
        if let authentication { headers.append(["name": "Authentication-Results", "value": authentication]) }
        headers += extra.map { ["name": $0.0, "value": $0.1] }
        let object: [String: Any] = ["id": "message", "threadId": "thread", "payload": ["headers": headers]]
        return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
