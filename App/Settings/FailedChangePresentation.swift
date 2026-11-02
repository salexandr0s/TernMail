import Foundation
import GmailAPI
import MailStore
import MessageContent

/// Recovery rows name the durable intent and its cached sources, without
/// exposing opaque provider IDs or retaining message bodies.
struct FailedChangePresentation: Identifiable, Sendable {
    let action: PendingAction
    let targetDescription: String
    var intentDescription: String? = nil
    let sources: [Source]
    let draftID: String?
    var id: Int64? { action.id }

    struct Source: Identifiable, Sendable {
        let link: MailLink
        let title: String
        var id: MailLink { link }
    }

    static func resolve(_ action: PendingAction, in transaction: CacheTransaction) throws -> Self {
        if let draftID = action.localDraftID,
           let draft = try transaction.localDraft(id: draftID), draft.accountID == action.accountID {
            return Self(action: action, targetDescription: subject(draft.content.subject), sources: [], draftID: draftID)
        }
        if let change = action.settingsChange {
            return Self(action: action, targetDescription: describe(change), sources: [], draftID: nil)
        }
        if let change = action.labelChange {
            let name = change.newName ?? change.oldName ?? change.deletedLabel?.name ?? "Label no longer available"
            return Self(action: action, targetDescription: name, sources: [], draftID: nil)
        }

        // Message operations retain exact message links. Thread operations may
        // also carry message IDs for undo; those are not additional targets.
        let messageOperation: Bool = switch action.kind {
        case .modifyMessages, .trashMessages, .untrashMessages, .deleteMessages: true
        default: false
        }
        var sources: [Source] = []
        let targetCount = messageOperation ? action.messageIDs.count : action.threadIDs.count
        if messageOperation {
            for id in action.messageIDs.prefix(5) {
                guard let message = try transaction.message(id: id, accountID: action.accountID) else { continue }
                sources.append(Source(link: MailLink(accountID: action.accountID, threadID: message.threadID, messageID: id),
                                      title: subject(message.subject)))
            }
        } else {
            for id in action.threadIDs.prefix(5) {
                guard let thread = try transaction.thread(id: id, accountID: action.accountID) else { continue }
                sources.append(Source(link: MailLink(accountID: action.accountID, threadID: id), title: subject(thread.subject)))
            }
        }
        let description: String
        if targetCount == 1 {
            description = sources.first?.title ?? "Original mail is no longer cached"
        } else if targetCount > 1 {
            let count = messageOperation ? "\(targetCount) messages" : "\(targetCount) conversations"
            description = sources.first.map { "\(count), including “\($0.title)”" } ?? "\(count) · Originals are no longer cached"
        } else {
            description = action.localDraftID == nil ? "Original item is no longer available" : "Draft is no longer available"
        }
        var presentation = Self(action: action, targetDescription: description, sources: sources, draftID: nil)
        if action.kind == .modifyMessages || action.kind == .modifyThreads {
            let labels = try transaction.labels(accountID: action.accountID)
            let names = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
            func describeLabels(_ ids: [String]) -> String {
                ids.map { id in
                    names[id] ?? systemLabelName(id) ?? "Unavailable label"
                }.joined(separator: ", ")
            }
            var changes: [String] = []
            if !action.addLabelIDs.isEmpty { changes.append("Add: \(describeLabels(action.addLabelIDs))") }
            if !action.removeLabelIDs.isEmpty { changes.append("Remove: \(describeLabels(action.removeLabelIDs))") }
            if !changes.isEmpty { presentation.intentDescription = changes.joined(separator: " · ") }
        }
        return presentation
    }

    private static func systemLabelName(_ id: String) -> String? {
        switch id {
        case SystemLabel.inbox: "Inbox"
        case SystemLabel.unread: "Unread"
        case SystemLabel.starred: "Starred"
        case SystemLabel.important: "Important"
        case SystemLabel.sent: "Sent"
        case SystemLabel.draft: "Drafts"
        case SystemLabel.spam: "Spam"
        case SystemLabel.trash: "Trash"
        default: nil
        }
    }

    private static func subject(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No Subject" : trimmed
    }

    private static func describe(_ change: PendingAction.SettingsChange) -> String {
        switch change {
        case .signature(let address, _, _): return "Signature for \(address)"
        case .vacation(_, let new, _): return "Vacation responder: \(subject(new.responseSubject ?? ""))"
        case .createFilter(let filter, _), .deleteFilter(_, let filter, _): return describe(filter)
        case .replaceFilter(_, _, let filter, _, _): return describe(filter)
        }
    }

    private static func describe(_ filter: GmailFilter) -> String {
        var details: [String] = []
        let criteria = filter.criteria
        for (title, value) in [("From", criteria.from), ("To", criteria.to), ("Subject", criteria.subject),
                               ("Contains", criteria.query), ("Excludes", criteria.negatedQuery)] {
            if let value, !value.isEmpty { details.append("\(title): \(value)") }
        }
        if criteria.hasAttachment == true { details.append("Has attachments") }
        if criteria.excludeChats == true { details.append("Excludes chats") }
        if let size = criteria.size { details.append("Size \(criteria.sizeComparison == .smaller ? "under" : "over") \(size) bytes") }
        return details.isEmpty ? "Filter for matching mail" : details.joined(separator: " · ")
    }
}
