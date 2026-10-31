import Foundation
import MailStore
import SyncEngine

extension MailboxModel {
    func showSnoozeDate(forRows rows: Set<MailListRowID>) {
        guard !rows.isEmpty, rows.allSatisfy({ account(id: $0.accountID)?.snoozeKeeper != nil }) else { return }
        snoozeRowTargets = rows
        snoozeDateTargets = Set(rows.map(\.threadKey))
    }

    @discardableResult
    func snoozeRows(_ rows: Set<MailListRowID>, until wakeAt: Date) -> Task<Void, Never>? {
        snoozeDateTargets = nil
        snoozeRowTargets = nil
        guard wakeAt > .now, !rows.isEmpty else {
            notice = Notice(message: "Choose a time later than now.", isError: true)
            return nil
        }
        let targets = actionTargets(forRows: rows)
        if !search.isActive, selectedLabelID == SystemLabel.inbox { selectRow(after: rows) }
        return queueUndoable("Snooze", confirmation: "Mail snoozed", for: Set(rows.map(\.threadKey)),
            revert: { owner, receipt in try await owner.snoozeKeeper?.undoSnooze(receipt) }) { owner, _ in
                guard let target = targets.first(where: { $0.accountID == owner.account.id })?.target else { return nil }
                return try await owner.snoozeKeeper?.snooze(target: target, until: wakeAt)
            }
    }

    @discardableResult
    func unsnoozeRows(_ rows: Set<MailListRowID>) -> Task<Void, Never>? {
        let targets = actionTargets(forRows: rows)
        guard !targets.isEmpty else { return nil }
        if showsSnoozed { selectRow(after: rows) }
        return Task {
            do {
                for (accountID, target) in targets {
                    try await account(id: accountID)?.snoozeKeeper?.unsnooze(target: target)
                }
            } catch { notice = Notice(message: "Couldn't return this mail to the Inbox. Try again.", isError: true) }
        }
    }
}
