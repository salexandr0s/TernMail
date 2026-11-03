import Foundation
import GmailAPI

/// Receiver evidence is trusted only at Gmail's delivery boundary. Imported
/// messages with fabricated receiver traces are outside that boundary. DMARC
/// authenticates the From domain's alignment, not a person's mailbox ownership.
public enum SenderImagePolicy {
    public static let metadataHeaders = ["Authentication-Results"]

    public static func verifiedSender(in message: GmailMessage) -> String? {
        let headers = message.payload?.headers ?? []
        let senders = headers.filter { $0.name.caseInsensitiveCompare("From") == .orderedSame }
        guard senders.count == 1, let sender = senders.first.flatMap({ address(in: $0.value) }),
              let domain = sender.split(separator: "@").last.map(String.init),
              let first = headers.first(where: { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame }),
              let authentication = unfoldedWithoutComments(first.value) else { return nil }
        let sections = authentication.split(separator: ";", omittingEmptySubsequences: false)
        guard sections.first?.trimmingCharacters(in: .whitespaces).lowercased() == "mx.google.com" else { return nil }
        let dmarc = sections.dropFirst().filter { section in
            section.trimmingCharacters(in: .whitespaces).prefix(while: {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }).lowercased() == "dmarc"
        }
        guard dmarc.count == 1, let section = dmarc.first else { return nil }
        let assignment = section.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard assignment.count == 2,
              assignment[0].trimmingCharacters(in: .whitespaces).lowercased() == "dmarc" else { return nil }
        let tokens = assignment[1].split(whereSeparator: \.isWhitespace)
        guard tokens.first?.lowercased() == "pass" else { return nil }
        var properties: [String: String] = [:]
        for token in tokens.dropFirst() {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = pair[0].lowercased()
            guard properties[key] == nil else { return nil }
            properties[key] = String(pair[1]).lowercased()
        }
        guard properties["header.from"] == domain else { return nil }
        return sender
    }

    /// A cached positive result belongs to this exact From address. A changed
    /// or ambiguous From cannot inherit evidence from an earlier metadata read.
    public static func verifiedAddress(from: String, evidence: String?) -> String? {
        guard let sender = address(in: from), sender == evidence else { return nil }
        return sender
    }

    private static func address(in from: String) -> String? {
        guard from.utf8.count <= 8_192,
              !from.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let addresses = EmailAddress.parseList(from)
        guard addresses.count == 1, let sender = addresses.first, sender.isValid,
              let domain = sender.address.split(separator: "@").last.map(String.init),
              NewsletterURLPolicy.isPublicHostname(domain) else { return nil }
        return sender.normalized
    }

    private static func unfoldedWithoutComments(_ value: String) -> String? {
        guard value.utf8.count <= 32_768 else { return nil }
        let unfolded = value.replacingOccurrences(of: "\r\n[ \t]+", with: " ", options: .regularExpression)
        guard !unfolded.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" || $0.value == 127 }) else { return nil }
        var depth = 0
        var escaped = false
        var result = ""
        for character in unfolded {
            if escaped { escaped = false; if depth == 0 { return nil }; continue }
            if character == "\\" { escaped = true; continue }
            if character == "(" { depth += 1; result.append(" "); continue }
            if character == ")" { guard depth > 0 else { return nil }; depth -= 1; result.append(" "); continue }
            if depth == 0 { result.append(character) }
        }
        return depth == 0 && !escaped ? result : nil
    }
}

/// A remembered permission lookup may finish after the reader changes message,
/// account, From, or receiver evidence. Its granted identity must still match.
public struct SenderImageIdentity: Hashable, Sendable {
    public let accountID: String
    public let messageID: String
    public let from: String
    public let verifiedSender: String?

    public init(accountID: String, messageID: String, from: String, verifiedSender: String?) {
        self.accountID = accountID
        self.messageID = messageID
        self.from = from
        self.verifiedSender = verifiedSender
    }

    public var address: String? { SenderImagePolicy.verifiedAddress(from: from, evidence: verifiedSender) }

    public func permitsRemembered(_ granted: Self?) -> Bool { address != nil && self == granted }

    public func allowsImages(blocksRemoteImages: Bool, explicit: Self?, remembered: Self?) -> Bool {
        self == explicit || !blocksRemoteImages || permitsRemembered(remembered)
    }
}
