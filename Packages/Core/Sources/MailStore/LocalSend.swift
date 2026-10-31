import Foundation
import GRDB
import MessageContent

/// A queued send, shown as a message in its conversation and in Sent from
/// the moment it is queued until Gmail's copy replaces it. Undo and a refusal
/// take it away again, so a send that fails shows only in the Outbox.
///
/// The message is the cache's own. Its ID starts with `local-send:`, and so
/// does its thread's when Gmail hasn't placed the draft in a conversation.
/// `enqueue` leaves such IDs out of every change, so they never reach Gmail.
/// Its history ID is 0, and it carries `LocalSend.label` beside Sent.
public enum LocalSend {
    /// Marks a provisional message. No `label` row exists for it, so it shows
    /// as no chip and in no mailbox of its own.
    public static let label = "TERN_SENDING"
    static let idPrefix = "local-send:"
    static let snippetLength = 200

    /// The provisional message of a local draft's send.
    public static func messageID(localDraftID: String) -> String { idPrefix + localDraftID }

    /// Whether a message or thread ID is a provisional send's, which Gmail doesn't know.
    public static func isProvisional(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The local draft a provisional message stands for, whose send undo cancels.
    public static func localDraftID(messageID: String) -> String? {
        isProvisional(messageID) ? String(messageID.dropFirst(idPrefix.count)) : nil
    }

    /// What only the engine knows about a send: the address it goes out from,
    /// under the name Gmail gives it, and the text it carries.
    public struct Rendering: Sendable, Equatable {
        public var sender: EmailAddress
        public var html: String?
        public var plainText: String

        public init(sender: EmailAddress, html: String?, plainText: String) {
            self.sender = sender
            self.html = html
            self.plainText = plainText
        }
    }

    /// The start of the text on one line, standing in for Gmail's snippet.
    static func snippet(_ plainText: String) -> String {
        String(plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(snippetLength))
    }

    /// An address header as Gmail reports one: decoded, with a name quoted
    /// when it holds header punctuation.
    static func header(_ addresses: [EmailAddress]) -> String {
        addresses.map { address in
            guard let name = address.name else { return address.address }
            let phrase = name.contains(where: { "()<>[]:;@\\,.\"".contains($0) })
                ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                : name
            return "\(phrase) <\(address.address)>"
        }.joined(separator: ", ")
    }
}

extension CacheTransaction {
    /// Stores the provisional message of a send just queued for `draft`, dated
    /// `now`, with its body, so opening it asks Gmail for nothing. Attachments
    /// show once Gmail's copy arrives. Returns its thread, which the caller rebuilds.
    func insertLocalSend(for draft: LocalDraft, rendering: LocalSend.Rendering, now: Date) throws -> String {
        let id = LocalSend.messageID(localDraftID: draft.id)
        let threadID = draft.threadID ?? id
        // A recipient still being typed stays out of the send, as it does here.
        let to = draft.to.filter(\.isValid)
        let cc = draft.cc.filter(\.isValid)
        let attachmentBytes = try outgoingAttachments(localDraftID: draft.id).reduce(0) { $0 + $1.size }
        let record = MessageRecord(
            accountID: draft.accountID, id: id, threadID: threadID, historyID: 0, date: now,
            snippet: LocalSend.snippet(rendering.plainText),
            sender: LocalSend.header([rendering.sender]),
            recipients: LocalSend.header(to),
            cc: cc.isEmpty ? nil : LocalSend.header(cc),
            subject: draft.subject,
            sizeEstimate: (rendering.html?.utf8.count ?? 0) + rendering.plainText.utf8.count + attachmentBytes,
            rfcMessageID: draft.rfcMessageID,
            inReplyTo: draft.inReplyTo,
            referencesHeader: draft.references.isEmpty ? nil : draft.references.joined(separator: " ")
        )
        try upsertMessages([MessageUpdate(record: record, labelIDs: [SystemLabel.sent, LocalSend.label])])
        try saveBodies([MessageBodyRecord(
            accountID: draft.accountID, messageID: id, html: rendering.html, plainText: rendering.plainText, fetchedAt: now
        )])
        try setBodyEnrichedAt(now, messageID: id, accountID: draft.accountID)
        return threadID
    }

    /// Removes a local draft's provisional message, if it has one, and
    /// returns its thread, which the caller rebuilds.
    func deleteLocalSend(localDraftID: String, accountID: String) throws -> Set<String> {
        try deleteMessages(ids: [LocalSend.messageID(localDraftID: localDraftID)], accountID: accountID)
    }

    /// Removes provisional messages whose draft is gone or no longer sending.
    /// Every path that ends a send removes its message as it goes, so only a
    /// fault leaves one behind.
    func deleteOrphanedLocalSends(accountID: String) throws {
        let orphans = try String.fetchAll(db, sql: """
            SELECT message.id
            FROM message
            LEFT JOIN localDraft ON localDraft.accountID = message.accountID
                AND ? || localDraft.id = message.id AND localDraft.state = ?
            WHERE message.accountID = ? AND message.id GLOB ? AND localDraft.id IS NULL
            """, arguments: [LocalSend.idPrefix, LocalDraft.State.sending.rawValue, accountID, LocalSend.idPrefix + "*"])
        try rebuildThreads(try deleteMessages(ids: orphans, accountID: accountID), accountID: accountID)
    }
}
