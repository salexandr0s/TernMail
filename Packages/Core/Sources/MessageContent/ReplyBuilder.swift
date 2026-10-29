import Foundation
import GmailAPI
import SwiftSoup

/// What a reply or forward takes from the message it answers.
public struct OriginalMessage: Sendable, Equatable {
    public var threadID: String
    public var from: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var subject: String
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var body: ExtractedBody

    public init(
        threadID: String,
        from: [EmailAddress],
        replyTo: [EmailAddress] = [],
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        subject: String = "",
        date: Date? = nil,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        body: ExtractedBody = ExtractedBody()
    ) {
        self.threadID = threadID
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.body = body
    }

    /// Reads the headers and text of a `full`-format message.
    public init(_ message: GmailMessage) {
        let addresses = { (name: String) in message.header(name).map(EmailAddress.parseList) ?? [] }
        self.init(
            threadID: message.threadId,
            from: addresses("From"),
            replyTo: addresses("Reply-To"),
            to: addresses("To"),
            cc: addresses("Cc"),
            subject: message.header("Subject").map(MIMEReader.decodeEncodedWords) ?? "",
            date: message.date,
            messageID: message.header("Message-ID").flatMap { Self.messageIDs(in: $0).first },
            inReplyTo: message.header("In-Reply-To").flatMap { Self.messageIDs(in: $0).first },
            references: message.header("References").map(Self.messageIDs) ?? [],
            body: MIMEParts.body(of: message)
        )
    }

    /// The `<id>` tokens in a header, which senders separate with spaces, commas or line breaks.
    public static func messageIDs(in header: String) -> [String] {
        // Regex isn't Sendable, so it can't be a shared static.
        let id = #/<[^<>\s]+>/#
        return header.matches(of: id).map { String($0.output) }
    }
}

public enum ReplyKind: String, Sendable, Equatable, Codable {
    case reply, replyAll, forward
}

/// The fields a new reply or forward starts with.
public struct ReplyDraft: Sendable, Equatable {
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var subject: String
    /// Forwards stay in the original's thread too, as they do in Gmail.
    public var threadID: String
    public var inReplyTo: String?
    public var references: [String]
    /// Goes after the new text in the HTML part.
    public var quotedHTML: String
    /// Goes after the new text in the plain text part.
    public var quotedPlainText: String
}

public enum ReplyBuilder {
    /// - Parameter ownAddresses: The account's addresses, which a reply never goes back to.
    public static func draft(
        _ kind: ReplyKind,
        replyingTo original: OriginalMessage,
        ownAddresses: Set<String>,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> ReplyDraft {
        let (to, cc) = recipients(kind, original: original, ownAddresses: Set(ownAddresses.map { $0.lowercased() }))
        var references = original.references
        if references.isEmpty, let parent = original.inReplyTo { references = [parent] }
        if let id = original.messageID, !references.contains(id) { references.append(id) }

        let date = original.date.map { formatted($0, locale: locale, timeZone: timeZone) }
        let quotedHTML: String
        let quotedPlainText: String
        switch kind {
        case .reply, .replyAll:
            let sender = original.from.first?.displayString ?? "Someone"
            let attribution = date.map { "On \($0), \(sender) wrote:" } ?? "\(sender) wrote:"
            quotedHTML = "<br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">"
                + MessageDocument.escaped(attribution)
                + "<br></div><blockquote class=\"gmail_quote\" style=\"margin:0 0 0 0.8ex;border-left:1px solid #ccc;padding-left:1ex\">"
                + originalHTML(original.body) + "</blockquote></div>"
            quotedPlainText = attribution + "\n" + quoted(originalPlainText(original.body))
        case .forward:
            let list = { (addresses: [EmailAddress]) in addresses.map(\.displayString).joined(separator: ", ") }
            let fields: [(String, String?)] = [
                ("From", original.from.isEmpty ? nil : list(original.from)),
                ("Date", date),
                ("Subject", original.subject),
                ("To", original.to.isEmpty ? nil : list(original.to)),
                ("Cc", original.cc.isEmpty ? nil : list(original.cc)),
            ]
            let header = ["---------- Forwarded message ---------"]
                + fields.compactMap { name, value in value.map { "\(name): \($0)" } }
            quotedHTML = "<br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">"
                + header.map(MessageDocument.escaped).joined(separator: "<br>")
                + "<br></div><br>" + originalHTML(original.body) + "</div>"
            quotedPlainText = header.joined(separator: "\n") + "\n\n" + originalPlainText(original.body)
        }

        return ReplyDraft(
            to: to,
            cc: cc,
            subject: subject(original.subject, for: kind),
            threadID: original.threadID,
            inReplyTo: original.messageID,
            references: references,
            quotedHTML: quotedHTML,
            quotedPlainText: quotedPlainText
        )
    }

    /// Reply goes to Reply-To, or From when there is none. Reply all adds the
    /// other recipients. Replying to your own message goes to its recipients.
    static func recipients(
        _ kind: ReplyKind,
        original: OriginalMessage,
        ownAddresses: Set<String>
    ) -> (to: [EmailAddress], cc: [EmailAddress]) {
        let isOwn = { (address: EmailAddress) in ownAddresses.contains(address.normalized) }
        let sentByMe = original.from.contains(where: isOwn)
        let sender = original.replyTo.isEmpty ? original.from : original.replyTo
        let primary = sentByMe ? original.to : sender
        var to: [EmailAddress]
        var cc: [EmailAddress]
        switch kind {
        case .forward:
            return ([], [])
        case .reply:
            to = primary
            cc = []
        case .replyAll:
            to = sentByMe ? original.to : sender + original.to
            cc = original.cc
        }
        to = unique(to.filter { !isOwn($0) })
        // A note to yourself is answered to yourself.
        if to.isEmpty { to = unique(primary) }
        let inTo = Set(to.map(\.normalized))
        cc = unique(cc.filter { !isOwn($0) && !inTo.contains($0.normalized) })
        return (to, cc)
    }

    /// Adds "Re:" or "Fwd:" unless the subject already starts with it.
    static func subject(_ subject: String, for kind: ReplyKind) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let (prefix, recognized) = kind == .forward ? ("Fwd:", ["fwd:", "fw:"]) : ("Re:", ["re:"])
        let lowered = trimmed.lowercased()
        if recognized.contains(where: lowered.hasPrefix) { return trimmed }
        return trimmed.isEmpty ? prefix : "\(prefix) \(trimmed)"
    }

    private static func unique(_ addresses: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.normalized).inserted }
    }

    /// The original HTML without active content, or the plain text as HTML.
    private static func originalHTML(_ body: ExtractedBody) -> String {
        if let html = body.html, let document = try? SwiftSoup.parse(html),
           (try? HTMLSanitizer.clean(document, keepingRemoteLoads: true)) != nil, let content = document.body() {
            document.outputSettings().prettyPrint(pretty: false)
            if let inner = try? content.html() { return inner }
        }
        let text = (body.plainText ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        return MessageDocument.linkified(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func originalPlainText(_ body: ExtractedBody) -> String {
        if let plainText = body.plainText { return plainText.replacingOccurrences(of: "\r\n", with: "\n") }
        guard let html = body.html else { return "" }
        return HTMLImporter.importHTML(html, detachingQuote: false).document.plainText()
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.isEmpty ? ">" : line.hasPrefix(">") ? ">\(line)" : "> \(line)" }
            .joined(separator: "\n")
    }

    private static func formatted(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
