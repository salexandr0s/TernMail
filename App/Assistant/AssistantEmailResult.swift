import Foundation
import MailStore

/// Mail identity and display metadata come from Tern. Only the short explanation
/// is supplied by the assistant when it selects a retrieved conversation.
struct AssistantEmailResult: Identifiable, Sendable, Equatable {
    let source: AssistantSource
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let date: Date?
    let isUnread: Bool
    let isStarred: Bool
    let messageCount: Int
    let accountEmail: String
    let labels: [LabelRecord]
    var reason: String?
    let avatarData: Data?

    var id: String {
        AssistantSource(accountID: source.accountID, threadID: source.threadID,
                        messageID: nil, partID: nil, title: subject).id
    }

    init(source: AssistantSource, senderName: String, senderEmail: String,
         subject: String, snippet: String, date: Date?, isUnread: Bool,
         isStarred: Bool, messageCount: Int, accountEmail: String,
         labels: [LabelRecord] = [], reason: String? = nil, avatarData: Data? = nil) {
        self.source = source
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.messageCount = messageCount
        self.accountEmail = accountEmail
        self.labels = labels
        self.reason = reason
        self.avatarData = avatarData
    }
}
