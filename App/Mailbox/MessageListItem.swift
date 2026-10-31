import Foundation
import MailStore
import MessageContent

/// A row retains the message identity independently of its reader conversation.
struct MailListRowID: Hashable, Sendable, Comparable {
    let accountID: String
    let threadID: String
    var messageID: String?
    var threadKey: ThreadKey { ThreadKey(accountID: accountID, threadID: threadID) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.accountID, lhs.threadID, lhs.messageID ?? "") < (rhs.accountID, rhs.threadID, rhs.messageID ?? "")
    }
}

/// Reuses the displayed rows while selection, toolbar or sync status changes.
/// Callers still read every observable input before consulting this cache.
final class MessageListProjection {
    struct Input: Equatable {
        let threads: [ThreadRecord]
        let entries: [MessageListEntry]
        let conversations: Bool
        let filters: Set<MailQuickFilter>
        let mailboxID: String?
        let categories: [String: Set<String>]
        let addresses: [String: Set<String>]
    }

    private var previous: Input?
    private var result: [MessageListItem] = []

    func items(for input: Input) -> [MessageListItem] {
        guard previous != input else { return result }
        result = MessageListItem.project(threads: input.threads, entries: input.entries,
            conversations: input.conversations, filters: input.filters, mailboxID: input.mailboxID,
            categories: input.categories, addresses: input.addresses)
        previous = input
        return result
    }
}

struct MessageListItem: Identifiable, Equatable {
    let id: MailListRowID
    let thread: ThreadRecord
    let messages: [MessageListEntry]
    var labels: Set<String> { messages.reduce(into: []) { $0.formUnion($1.labels) } }
    var attachments: [AttachmentRecord] {
        var seen = Set<String>()
        return messages.flatMap(\.attachments).filter { seen.insert($0.messageID + ":" + $0.partID).inserted }
    }
    var recipients: String { messages.first?.message.recipients ?? "" }

    func displayedLabels(from available: [LabelRecord], mailboxID: String?) -> [LabelRecord] {
        let applied = labels
        return available.filter {
            applied.contains($0.id) && (!$0.isSystem || $0.id != mailboxID)
                && ![SystemLabel.unread, SystemLabel.starred, SystemLabel.important, SystemLabel.allMail].contains($0.id)
        }.sorted { lhs, rhs in
            let leftSelected = !lhs.isSystem && lhs.id == mailboxID
            let rightSelected = !rhs.isSystem && rhs.id == mailboxID
            if leftSelected != rightSelected { return leftSelected }
            if lhs.isSystem != rhs.isSystem { return !lhs.isSystem }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func project(threads: [ThreadRecord], entries: [MessageListEntry], conversations: Bool,
                        filters: Set<MailQuickFilter>, mailboxID: String?, categories: [String: Set<String>],
                        addresses: [String: Set<String>]) -> [MessageListItem] {
        let threadMap = Dictionary(threads.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let filtered = entries.filter { entry in
            guard threadMap[ThreadKey(accountID: entry.message.accountID, threadID: entry.message.threadID)] != nil else { return false }
            if let mailboxID, mailboxID != MailboxModel.snoozedID {
                if mailboxID == SystemLabel.allMail {
                    guard entry.labels.isDisjoint(with: [SystemLabel.trash, SystemLabel.spam]) else { return false }
                } else if !entry.labels.contains(mailboxID) { return false }
            }
            if mailboxID == SystemLabel.inbox,
               !entry.labels.isDisjoint(with: categories[entry.message.accountID] ?? []) { return false }
            for filter in filters {
                switch filter {
                case .unread: if !entry.labels.contains(SystemLabel.unread) { return false }
                case .starred: if !entry.labels.contains(SystemLabel.starred) { return false }
                case .attachments: if entry.attachments.isEmpty { return false }
                case .important: if !entry.labels.contains(SystemLabel.important) { return false }
                case .addressedToMe:
                    let recipients = EmailAddress.parseList(entry.message.recipients) + EmailAddress.parseList(entry.message.cc ?? "")
                    if !recipients.contains(where: { addresses[entry.message.accountID]?.contains($0.normalized) == true }) { return false }
                }
            }
            return true
        }
        if !conversations {
            return filtered.map { entry in
                MessageListItem(id: .init(accountID: entry.message.accountID, threadID: entry.message.threadID, messageID: entry.message.id),
                                thread: entry.rowThread, messages: [entry])
            }
        }
        let groups = Dictionary(grouping: filtered) { ThreadKey(accountID: $0.message.accountID, threadID: $0.message.threadID) }
        return threads.compactMap { thread in
            guard let messages = groups[thread.key], !messages.isEmpty else { return nil }
            var displayed = thread
            displayed.isUnread = messages.contains { $0.labels.contains(SystemLabel.unread) }
            displayed.isStarred = messages.contains { $0.labels.contains(SystemLabel.starred) }
            displayed.lastDate = messages.map(\.message.date).max() ?? thread.lastDate
            return MessageListItem(id: .init(accountID: thread.accountID, threadID: thread.id), thread: displayed, messages: messages)
        }
    }
}
