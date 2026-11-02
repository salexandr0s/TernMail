import Foundation
import MessageContent

public struct ReadReceiptRecipientStatus: Sendable, Equatable, Identifiable {
    public let address: String
    /// Arrival of a matching displayed receipt, not the time the message was read.
    public let receivedAt: Date?
    public var id: String { address }

    public init(address: String, receivedAt: Date?) {
        self.address = address
        self.receivedAt = receivedAt
    }
}

public struct ReadReceiptStatus: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let rfcMessageID: String
    public let messageID: String?
    public let threadID: String?
    public let subject: String
    public let sentAt: Date
    public let recipients: [ReadReceiptRecipientStatus]
    public var id: String { accountID + "/" + rfcMessageID }

    public init(accountID: String, rfcMessageID: String, messageID: String?, threadID: String?, subject: String,
                sentAt: Date, recipients: [ReadReceiptRecipientStatus]) {
        self.accountID = accountID; self.rfcMessageID = rfcMessageID; self.messageID = messageID
        self.threadID = threadID; self.subject = subject; self.sentAt = sentAt; self.recipients = recipients
    }
}

extension LocalDraft {
    /// The new receipt option is absent from drafts encoded before its migration.
    /// All existing fields retain their original decoding requirements.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try c.decode(String.self, forKey: .accountID)
        gmailDraftID = try c.decodeIfPresent(String.self, forKey: .gmailDraftID)
        savedMessageID = try c.decodeIfPresent(String.self, forKey: .savedMessageID)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        kind = try c.decode(Kind.self, forKey: .kind)
        sourceMessageID = try c.decodeIfPresent(String.self, forKey: .sourceMessageID)
        to = try c.decode([EmailAddress].self, forKey: .to)
        cc = try c.decode([EmailAddress].self, forKey: .cc)
        bcc = try c.decode([EmailAddress].self, forKey: .bcc)
        subject = try c.decode(String.self, forKey: .subject)
        body = try c.decode(ComposeDocument.self, forKey: .body)
        fromAddress = try c.decodeIfPresent(String.self, forKey: .fromAddress)
        signatureHTML = try c.decodeIfPresent(String.self, forKey: .signatureHTML)
        composeFont = try c.decode(ComposeFont.self, forKey: .composeFont)
        signatureAboveQuote = try c.decode(Bool.self, forKey: .signatureAboveQuote)
        signatureSeparator = try c.decode(Bool.self, forKey: .signatureSeparator)
        archiveAfterSend = try c.decode(Bool.self, forKey: .archiveAfterSend)
        requestsReadReceipt = try c.decodeIfPresent(Bool.self, forKey: .requestsReadReceipt) ?? false
        calendarPart = try c.decodeIfPresent(String.self, forKey: .calendarPart)
        quotedHTML = try c.decodeIfPresent(String.self, forKey: .quotedHTML)
        quotedPlainText = try c.decodeIfPresent(String.self, forKey: .quotedPlainText)
        rfcMessageID = try c.decode(String.self, forKey: .rfcMessageID)
        inReplyTo = try c.decodeIfPresent(String.self, forKey: .inReplyTo)
        references = try c.decode([String].self, forKey: .references)
        revision = try c.decode(Int.self, forKey: .revision)
        savedRevision = try c.decode(Int.self, forKey: .savedRevision)
        state = try c.decode(State.self, forKey: .state)
        sendError = try c.decodeIfPresent(String.self, forKey: .sendError)
        hasUnrecordedUpload = try c.decode(Bool.self, forKey: .hasUnrecordedUpload)
        sendRequested = try c.decode(Bool.self, forKey: .sendRequested)
        importPending = try c.decode(Bool.self, forKey: .importPending)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
