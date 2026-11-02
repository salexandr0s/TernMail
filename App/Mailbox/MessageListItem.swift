import Foundation
import Synchronization
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

/// Reuses rows by data/configuration revision. Selection never compares the
/// complete message arrays or rebuilds derived row presentation.
final class MessageListProjection {
    struct Key: Equatable, Sendable {
        let dataRevision: UInt64
        let contextRevision: UInt64
        let conversations: Bool
        let filters: Set<MailQuickFilter>
        let mailboxID: String?
    }

    struct Input: Sendable {
        let threads: [ThreadRecord]
        let entries: [MessageListEntry]
        let conversations: Bool
        let filters: Set<MailQuickFilter>
        let mailboxID: String?
        let categories: [String: Set<String>]
        let addresses: [String: Set<String>]
        let availableLabels: [String: [LabelRecord]]
    }

    private var previous: Key?
    private var result: [MessageListItem] = []
    private(set) var preparationCount = 0

    func cached(for key: Key) -> [MessageListItem]? { previous == key ? result : nil }

    func store(_ items: [MessageListItem], for key: Key) {
        result = items
        previous = key
        preparationCount += 1
    }

    static func prepare(_ input: Input, reusing previous: [MessageListItem] = []) -> [MessageListItem] {
        MessageListItem.project(threads: input.threads, entries: input.entries,
            conversations: input.conversations, filters: input.filters, mailboxID: input.mailboxID,
            categories: input.categories, addresses: input.addresses, availableLabels: input.availableLabels, reusing: previous)
    }
}

struct MessageListItem: Identifiable, Equatable, Sendable {
    let id: MailListRowID
    let thread: ThreadRecord
    let messages: [MessageListEntry]
    private let metadata: Metadata
    let sender: EmailAddress?
    let visibleLabels: [LabelRecord]

    var labels: Set<String> { metadata.labels }
    var attachments: [AttachmentRecord] { metadata.attachments }
    var recipients: String { messages.first?.message.recipients ?? "" }

    init(id: MailListRowID, thread: ThreadRecord, messages: [MessageListEntry],
         availableLabels: [LabelRecord] = [], mailboxID: String? = nil) {
        self.id = id
        self.thread = thread
        self.messages = messages
        let metadata = Metadata(messages: messages)
        self.metadata = metadata
        sender = EmailAddress.parseList(messages.first?.message.sender ?? thread.participants).first
        visibleLabels = Self.displayedLabels(applied: metadata.labels, from: availableLabels, mailboxID: mailboxID)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.thread == rhs.thread && lhs.messages == rhs.messages
            && lhs.visibleLabels == rhs.visibleLabels
    }

    /// Rows are prepared off-main and later read by the UI; protect shared lazy values.
    private final class Metadata: Sendable {
        let messages: [MessageListEntry]
        private let cached = Mutex(Values())

        private struct Values {
            var labels: Set<String>?
            var attachments: [AttachmentRecord]?
        }

        var labels: Set<String> {
            cached.withLock { values in
                if let labels = values.labels { return labels }
                let labels = messages.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
                values.labels = labels
                return labels
            }
        }

        var attachments: [AttachmentRecord] {
            cached.withLock { values in
                if let attachments = values.attachments { return attachments }
                var seen = Set<String>()
                let attachments = messages.flatMap(\.attachments).filter {
                    seen.insert($0.messageID + ":" + $0.partID).inserted
                }
                values.attachments = attachments
                return attachments
            }
        }

        init(messages: [MessageListEntry]) { self.messages = messages }
    }

    func displayedLabels(from available: [LabelRecord], mailboxID: String?) -> [LabelRecord] {
        Self.displayedLabels(applied: labels, from: available, mailboxID: mailboxID)
    }

    private static func displayedLabels(applied: Set<String>, from available: [LabelRecord], mailboxID: String?) -> [LabelRecord] {
        return available.filter {
            applied.contains($0.id) && (!$0.isSystem || $0.id != mailboxID)
                && ![SystemLabel.unread, SystemLabel.starred, SystemLabel.important, SystemLabel.allMail].contains($0.id)
        }.sorted { lhs, rhs in
            let leftSelected = !lhs.isSystem && lhs.id == mailboxID
            let rightSelected = !rhs.isSystem && rhs.id == mailboxID
            if leftSelected != rightSelected { return leftSelected }
            if lhs.isSystem != rhs.isSystem { return !lhs.isSystem }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func project(threads: [ThreadRecord], entries: [MessageListEntry], conversations: Bool,
                        filters: Set<MailQuickFilter>, mailboxID: String?, categories: [String: Set<String>],
                        addresses: [String: Set<String>], availableLabels: [String: [LabelRecord]] = [:],
                        reusing previous: [MessageListItem] = []) -> [MessageListItem] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func row(id: MailListRowID, thread: ThreadRecord, messages: [MessageListEntry]) -> MessageListItem {
            if let previous = previousByID[id], previous.thread == thread, previous.messages == messages { return previous }
            return MessageListItem(id: id, thread: thread, messages: messages,
                                   availableLabels: availableLabels[id.accountID] ?? [], mailboxID: mailboxID)
        }
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
                row(id: .init(accountID: entry.message.accountID, threadID: entry.message.threadID, messageID: entry.message.id),
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
            return row(id: .init(accountID: thread.accountID, threadID: thread.id), thread: displayed, messages: messages)
        }
    }
}
