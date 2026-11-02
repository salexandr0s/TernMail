import Foundation
import MailStore
import SyncEngine

extension MailboxModel {
    func toggleMessageStar(_ message: MessageDetail) {
        guard let owner = account(id: message.record.accountID) else { return }
        let action: MailAction = message.isStarred ? .unstar : .star
        queueUndoable(message.isStarred ? "Remove Star" : "Star", in: owner) {
            try await $0.perform(action, target: .messages([message.id]))
        }
    }

    func markConversationRead(_ key: ThreadKey, messageID: String? = nil) async {
        guard let owner = account(id: key.accountID) else { return }
        do {
            let unread = try await cache.read { tx in
                try tx.currentLabels(threadID: key.threadID, accountID: key.accountID).contains {
                    $0.value.contains(SystemLabel.unread) && (messageID == nil || $0.key == messageID)
                }
            }
            guard unread, !Task.isCancelled else { return }
            invalidateListSnapshots()
            defer { invalidateListSnapshots() }
            let target: MailActionTarget = messageID.map { .messages([$0]) } ?? .threads([key.threadID])
            _ = try await owner.engine.perform(.markRead, target: target)
        }
        catch { if !Task.isCancelled { notice = .init(message: "The reading state could not be updated.", isError: true) } }
    }

    func performReadingAction(_ action: MailAction, name: String, messageID: String, accountID: String) {
        guard let owner = account(id: accountID) else { return }
        queueUndoable(name, in: owner) { try await $0.perform(action, target: .messages([messageID])) }
    }

    func removeReadingLabel(_ labelID: String, messageID: String, accountID: String) {
        guard let owner = account(id: accountID) else { return }
        queueUndoable("Remove Label", in: owner) { try await $0.editLabels(target: .messages([messageID]), add: [], remove: [labelID]) }
    }

    /// Saves whether mail from `address` loads remote images in `accountID`,
    /// then tells the open messages from that sender.
    func setImageSenderAllowed(_ allowed: Bool, address: String, accountID: String) {
        Task {
            do {
                guard let store = accountStore else {
                    notice = .init(message: "This sender's image preference could not be saved.", isError: true)
                    return
                }
                try await store.setImageSenderAllowed(allowed, address: address, accountID: accountID)
                NotificationCenter.default.post(name: ReadingPreferences.imagePermissionChanged, object: nil,
                    userInfo: ["account": accountID, "sender": address.lowercased(), "allowed": allowed])
            } catch { notice = .init(message: "This sender's image preference could not be saved.", isError: true) }
        }
    }
}
