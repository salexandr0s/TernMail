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
        let target: MailActionTarget = messageID.map { .messages([$0]) } ?? .threads([key.threadID])
        do { _ = try await owner.engine.perform(.markRead, target: target) }
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
}
