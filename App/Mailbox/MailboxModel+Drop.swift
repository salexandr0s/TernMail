import Foundation
import MailStore
import MessageContent
import SyncEngine

enum ConversationDropAction: Equatable {
    case addLabel(String)
    case moveToLabel(String)
    case moveToInbox
    case archive
    case trash
    case spam

    /// Snoozed mail has to go back to the Inbox before it can move to a
    /// folder or be archived. Tagging, Trash and Spam keep the snooze.
    var refusesSnoozedMail: Bool {
        switch self {
        case .moveToLabel, .archive: true
        case .addLabel, .moveToInbox, .trash, .spam: false
        }
    }
}

extension ConversationDragItem {
    var rowID: MailListRowID {
        MailListRowID(accountID: link.accountID, threadID: link.threadID, messageID: link.messageID)
    }
}

extension MailboxModel {
    func dragItems(for rows: [MailListRowID]) -> [ConversationDragItem] {
        rows.map {
            ConversationDragItem(MailLink(accountID: $0.accountID, threadID: $0.threadID, messageID: $0.messageID),
                                 sourceLabelID: search.isActive ? nil : selectedLabelID)
        }
    }

    /// A regular drag moves mail. Option-drag applies a user label without moving it.
    static func dropAction(onto labelID: String, isUserLabel: Bool, copy: Bool = false) -> ConversationDropAction? {
        if isUserLabel { return copy ? .addLabel(labelID) : .moveToLabel(labelID) }
        switch labelID {
        case SystemLabel.inbox: return .moveToInbox
        case SystemLabel.allMail: return .archive
        case SystemLabel.trash: return .trash
        case SystemLabel.spam: return .spam
        case SystemLabel.starred, SystemLabel.unread, SystemLabel.important,
             "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS":
            return .addLabel(labelID)
        default: return nil
        }
    }

    func dropAction(for box: MailboxID, copy: Bool = false) -> ConversationDropAction? {
        guard !owners(of: box).isEmpty else { return nil }
        let isUserLabel: Bool
        if case .account(let accountID, let labelID) = box {
            isUserLabel = account(id: accountID)?.labels.contains { $0.id == labelID && !$0.isSystem } == true
        } else {
            isUserLabel = false
        }
        return Self.dropAction(onto: box.id, isUserLabel: isUserLabel, copy: copy)
    }

    func acceptsDrop(on box: MailboxID, rows: Set<MailListRowID>? = nil) -> Bool {
        guard dropAction(for: box) != nil else { return false }
        guard let rows else { return true }
        let allowedAccounts = Set(owners(of: box).map(\.account.id))
        guard !rows.isEmpty, rows.allSatisfy({ allowedAccounts.contains($0.accountID) }) else { return false }
        // Reject the whole drop if any account mixes messages and conversations.
        return actionTargets(forRows: rows).count == Set(rows.map(\.accountID)).count
    }

    @discardableResult
    func drop(_ items: [ConversationDragItem], on box: MailboxID, copy: Bool = false) -> Bool {
        queueDrop(items, on: box, copy: copy) != nil
    }

    /// Uses the drag's identities and source, never the current list selection.
    /// The task checks the mail before anything changes. A refused drop leaves
    /// the selection where it was and says why in a notice.
    @discardableResult
    func queueDrop(_ items: [ConversationDragItem], on box: MailboxID, copy: Bool = false) -> Task<Void, Never>? {
        let rows = Set(items.map(\.rowID))
        guard acceptsDrop(on: box, rows: rows), Set(items.map(\.sourceLabelID)).count == 1,
              let action = dropAction(for: box, copy: copy) else { return nil }
        let source = items.first?.sourceLabelID
        guard source != box.id else { return nil }
        if source == Self.snoozedID {
            if action.refusesSnoozedMail {
                notice = Notice(message: Self.snoozedDropNotice)
                return nil
            }
            if action == .moveToInbox { return unsnoozeRows(rows) }
        }
        let cache = cache
        let targets = actionTargets(forRows: rows)
        let keys = Set(rows.map(\.threadKey))
        let title = owners(of: box).first?.labels.first { $0.id == box.id && !$0.isSystem }?.name
            ?? SystemMailbox(labelID: box.id).title
        let subject = rows.count == 1 ? "Mail" : "\(rows.count) items"

        let name: String
        let confirmation: String
        switch action {
        case .addLabel:
            name = "Add Label"
            confirmation = "\(subject) added to “\(title)”"
        case .moveToInbox, .moveToLabel:
            name = "Move"
            confirmation = "\(subject) moved to “\(title)”"
        case .archive:
            name = "Archive"
            confirmation = "\(subject) archived"
        case .trash:
            name = "Move to Trash"
            confirmation = "\(subject) moved to Trash"
        case .spam:
            name = "Mark as Spam"
            confirmation = "\(subject) moved to Spam"
        }

        return Task {
            // Check the entire batch before changing any account. Search
            // results can contain snoozed mail without naming Snoozed as source.
            let validation: (valid: Bool, hasSnoozes: Bool)
            do {
                validation = try await cache.read { tx in
                    let valid = try rows.allSatisfy { row in
                        if let id = row.messageID {
                            return try tx.message(id: id, accountID: row.accountID)?.threadID == row.threadID
                        }
                        return try !tx.currentLabels(threadID: row.threadID, accountID: row.accountID).isEmpty
                    }
                    let hasSnoozes = try targets.contains {
                        try Self.hasSnooze($0.target, accountID: $0.accountID, in: tx)
                    }
                    return (valid: valid, hasSnoozes: hasSnoozes)
                }
            } catch {
                notice = Notice(message: Self.failureMessage(error), isError: true)
                return
            }
            guard validation.valid else {
                notice = Notice(message: rows.count == 1 ? "This mail is no longer available."
                                    : "Some of this mail is no longer available, so nothing changed.", isError: true)
                return
            }
            if validation.hasSnoozes, action.refusesSnoozedMail {
                notice = Notice(message: Self.snoozedDropNotice)
                return
            }
            let task = queueUndoable(name, confirmation: confirmation, for: keys) { owner, _ in
                guard let target = targets.first(where: { $0.accountID == owner.account.id })?.target else { return nil }
                switch action {
                case .addLabel(let label):
                    return try await owner.engine.editLabels(target: target, add: [label], remove: [])
                case .moveToLabel(let label):
                    let customSource = source.flatMap { id in owner.labels.first { $0.id == id && !$0.isSystem }?.id }
                    let remove = [SystemLabel.inbox, SystemLabel.trash, SystemLabel.spam] + (customSource.map { [$0] } ?? [])
                    return try await owner.engine.editLabels(target: target, add: [label], remove: remove)
                case .moveToInbox:
                    let customSource = source.flatMap { id in owner.labels.first { $0.id == id && !$0.isSystem }?.id }
                    return try await owner.engine.editLabels(target: target, add: [SystemLabel.inbox],
                        remove: [SystemLabel.trash, SystemLabel.spam] + (customSource.map { [$0] } ?? []))
                case .archive:
                    return try await owner.engine.editLabels(target: target, add: [],
                        remove: [SystemLabel.inbox, SystemLabel.trash, SystemLabel.spam])
                case .trash:
                    return try await owner.engine.perform(.trash, target: target)
                case .spam:
                    return try await owner.engine.editLabels(target: target, add: [SystemLabel.spam],
                        remove: [SystemLabel.inbox, SystemLabel.trash])
                }
            }
            // The selection moves only once the drop is accepted.
            if task != nil, !search.isActive {
                switch action {
                case .trash, .spam: selectRow(after: rows)
                case .archive where selectedLabelID == SystemLabel.inbox || selectedLabelID == SystemLabel.trash || selectedLabelID == SystemLabel.spam:
                    selectRow(after: rows)
                case .moveToLabel, .moveToInbox:
                    if selectedLabelID == source { selectRow(after: rows) }
                default: break
                }
            }
            await task?.value
        }
    }

    private static let snoozedDropNotice = "Move this mail to Inbox to end its snooze before moving or archiving it. Hold Option to add a label while keeping the snooze."
}
