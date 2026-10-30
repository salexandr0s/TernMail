import Foundation
import GmailAPI
import MailStore
import MessageContent
import SyncEngine

extension MailboxModel {
    func nativeReplyMessageID(for link: MailLink, preferredMessageID: String? = nil) async -> String? {
        guard account(id: link.accountID) != nil else { return nil }
        let candidate = preferredMessageID ?? link.messageID
        return try? await cache.read { tx in
            if let candidate {
                guard let message = try tx.message(id: candidate, accountID: link.accountID),
                      message.threadID == link.threadID else { return nil }
                return candidate
            }
            return try tx.messages(threadID: link.threadID, accountID: link.accountID).last?.id
        }
    }

    /// Detached windows carry their own scope instead of borrowing the main list selection.
    @discardableResult
    func performNativeAction(_ action: MailAction, link: MailLink, undoManager: UndoManager?) async -> ActionReceipt? {
        guard let owner = account(id: link.accountID) else { return nil }
        do {
            if let messageID = link.messageID {
                let record = try await cache.read { try $0.message(id: messageID, accountID: link.accountID) }
                guard record?.threadID == link.threadID else { throw GmailError.invalidRequest("Mail link message identity") }
            }
            let target: MailActionTarget = link.messageID.map { .messages([$0]) } ?? .threads([link.threadID])
            guard let receipt = try await owner.engine.perform(action, target: target) else { return nil }
            undoManager?.registerUndo(withTarget: self) { mailbox in mailbox.undo(receipt) }
            let name = switch action {
            case .archive: "Archive"
            case .trash: "Move to Trash"
            case .markRead: "Mark as Read"
            case .markUnread: "Mark as Unread"
            case .star: "Star"
            case .unstar: "Remove Star"
            }
            undoManager?.setActionName(name)
            MailSounds.playAction(action)
            return receipt
        } catch {
            notice = Notice(message: "Couldn't change this conversation. Try again.", isError: true)
            return nil
        }
    }

    func requestFilter(sender: String?, recipients: String?, subject: String?, accountID: String) {
        guard account(id: accountID) != nil else { return }
        triage.filterRequest = SenderFilterRequest(accountID: accountID,
            criteria: .init(from: sender, to: recipients, subject: subject))
    }
}
