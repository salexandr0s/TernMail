import Foundation
import MailStore
import MessageContent
import SyncEngine

/// What dropping conversations on a sidebar mailbox does to them.
enum ConversationDropAction: Equatable {
    case addLabel(String)
    case moveToInbox
    case archive
    case trash
    case spam
}

extension ConversationDragItem {
    /// The list row the item came from, for drag containers keyed by row.
    var rowID: MailListRowID {
        MailListRowID(accountID: link.accountID, threadID: link.threadID, messageID: link.messageID)
    }
}

extension MailboxModel {
    /// Nil when a drop would change nothing: the mailbox already shown, or one
    /// mail can't be put into by hand (Starred, Sent, Drafts, Snoozed, Outbox).
    static func dropAction(onto labelID: String, isUserLabel: Bool, shown currentLabelID: String?) -> ConversationDropAction? {
        guard labelID != currentLabelID else { return nil }
        if isUserLabel { return .addLabel(labelID) }
        switch labelID {
        case SystemLabel.inbox: return .moveToInbox
        case SystemLabel.allMail: return .archive
        case SystemLabel.trash: return .trash
        case SystemLabel.spam: return .spam
        default: return nil
        }
    }

    /// Rows register as drop targets only while they take conversations.
    func acceptsDrop(on box: MailboxID) -> Bool {
        dropAction(for: box) != nil
    }

    /// Changes the dropped conversations the way `box` asks, through the action
    /// queue with Undo. Returns false when nothing queues, so the drag snaps back.
    @discardableResult
    func drop(_ items: [ConversationDragItem], on box: MailboxID) -> Bool {
        guard let action = dropAction(for: box) else { return false }
        // A row scoped to some accounts takes their mail only.
        let rows = Set(items.map(\.rowID)).filter { row in
            switch box {
            case .combined: true
            case .account(let accountID, _): row.accountID == accountID
            case .scoped(_, let accountIDs): accountIDs.contains(row.accountID)
            }
        }
        let targets = actionTargets(forRows: rows)
        guard !targets.isEmpty else { return false }
        let keys = Set(rows.map(\.threadKey))
        let subject = keys.count == 1 ? "Conversation" : "\(keys.count) conversations"
        let target = { (owner: AccountMailbox) in targets.first { $0.accountID == owner.account.id }?.target }
        switch action {
        case .addLabel(let labelID):
            let name = owners(of: box).first?.labels.first { $0.id == labelID }?.name ?? "the label"
            return queueUndoable("Add Label", confirmation: "\(subject) added to “\(name)”", for: keys) { owner, _ in
                guard let target = target(owner) else { return nil }
                return try await owner.engine.editLabels(target: target, add: [labelID], remove: [])
            } != nil
        case .moveToInbox:
            if showsSnoozed { return unsnoozeRows(rows) != nil }
            let shown = search.isActive ? nil : selectedLabelID
            if shown == SystemLabel.spam {
                triage.perform(.notSpam, targets: targets)
                selectRow(after: rows)
                return true
            }
            // Mail leaves Trash or a user label; elsewhere it is only added to the Inbox.
            let leaves = shown.map { label in
                label == SystemLabel.trash || accounts.contains { $0.labels.contains { $0.id == label && !$0.isSystem } }
            } ?? false
            if leaves { selectRow(after: rows) }
            return queueUndoable("Move to Inbox", confirmation: "\(subject) moved to the Inbox", for: keys) { owner, _ in
                guard let target = target(owner) else { return nil }
                return try await owner.engine.move(target: target, to: SystemLabel.inbox, from: shown ?? SystemLabel.inbox)
            } != nil
        case .archive:
            return performListAction(.archive, rows: rows) != nil
        case .trash:
            return performListAction(.trash, rows: rows) != nil
        case .spam:
            triage.perform(.spam, targets: targets)
            if !search.isActive { selectRow(after: rows) }
            return true
        }
    }

    private func dropAction(for box: MailboxID) -> ConversationDropAction? {
        var isUserLabel = false
        if case .account(let accountID, let labelID) = box {
            isUserLabel = account(id: accountID)?.labels.contains { $0.id == labelID && !$0.isSystem } == true
        }
        return Self.dropAction(onto: box.id, isUserLabel: isUserLabel, shown: search.isActive ? nil : selectedLabelID)
    }
}
