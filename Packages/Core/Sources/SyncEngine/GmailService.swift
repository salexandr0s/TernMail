import Foundation
import GmailAPI
import MailStore
import MessageContent

/// The Gmail calls sync makes. `GmailClient` is the real one; tests supply a
/// small in-memory mailbox.
public protocol GmailService: Sendable {
    func profile() async throws -> GmailProfile
    func labels() async throws -> [GmailLabel]
    func labels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>]
    func listMessages(
        query: String?,
        labelIDs: [String],
        includeSpamTrash: Bool,
        pageToken: String?,
        maxResults: Int
    ) async throws -> MessageListPage
    func messages(
        ids: [String],
        format: MessageFormat,
        metadataHeaders: [String]
    ) async throws -> [String: Result<GmailMessage, GmailError>]
    func thread(id: String, format: MessageFormat) async throws -> GmailThread
    func history(startHistoryID: String, pageToken: String?) async throws -> HistoryPage
    func modifyThreads(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws -> [String: GmailError]
    func trashThreads(ids: [String]) async throws -> [String: GmailError]
    func untrashThreads(ids: [String]) async throws -> [String: GmailError]
    func batchModifyMessages(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws
}

extension GmailClient: GmailService {}

/// Converts Gmail responses into cache records.
enum Mapping {
    static func label(_ label: GmailLabel, accountID: String) -> LabelRecord {
        LabelRecord(
            accountID: accountID,
            id: label.id,
            name: label.name,
            isSystem: label.isSystem,
            textColor: label.color?.textColor,
            backgroundColor: label.color?.backgroundColor,
            threadsTotal: label.threadsTotal,
            threadsUnread: label.threadsUnread
        )
    }

    /// Reject incomplete metadata rather than confirming a cursor past lost mail.
    static func message(_ message: GmailMessage, accountID: String) throws -> CacheTransaction.MessageUpdate {
        guard let historyID = message.historyId.flatMap(Int64.init), historyID > 0 else { throw SyncError.invalidHistoryID }
        let record = MessageRecord(
            accountID: accountID,
            id: message.id,
            threadID: message.threadId,
            historyID: historyID,
            date: message.date ?? .distantPast,
            snippet: HTMLEntities.decode(message.snippet ?? ""),
            sender: message.header("From") ?? "",
            recipients: message.header("To") ?? "",
            cc: message.header("Cc"),
            subject: message.header("Subject") ?? "",
            sizeEstimate: message.sizeEstimate ?? 0
        )
        return CacheTransaction.MessageUpdate(record: record, labelIDs: message.labelIds ?? [])
    }

    static func body(_ message: GmailMessage, accountID: String, fetchedAt: Date) -> MessageBodyRecord {
        let body = MIMEParts.body(of: message)
        return MessageBodyRecord(
            accountID: accountID,
            messageID: message.id,
            html: body.html,
            plainText: body.plainText,
            fetchedAt: fetchedAt
        )
    }
}

extension Array where Element: Hashable {
    /// Drops repeats, keeping the first occurrence of each element.
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
