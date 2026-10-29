import Foundation
import MailStore
import SyncEngine

/// Snooze from the toolbar, the context menu and the Message menu. Tern
/// keeps snoozes itself: Gmail sees an archive, then a return to the Inbox.
extension MailboxModel {
    /// Snoozing archives, so it's offered where Archive is.
    var canSnooze: Bool {
        snoozeKeeper != nil && offersArchive && !selectedThreadIDs.isEmpty
    }

    var showsSnoozed: Bool {
        selectedLabelID == Self.snoozedID && !search.isActive
    }

    /// When each snoozed conversation wakes, for the list's rows.
    var wakeTimes: [ThreadKey: Date] {
        Dictionary(snoozed.map { ($0.thread.key, $0.wakeAt) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether a snooze brought the conversation back to the Inbox.
    func isWoken(_ thread: ThreadRecord) -> Bool {
        thread.accountID == account.id && wokenThreadIDs.contains(thread.id)
    }

    /// Choose Date & Time, from the menus.
    func showSnoozeDate(for keys: Set<ThreadKey>? = nil) {
        let ids = keys ?? selectedThreadIDs
        guard snoozeKeeper != nil, !ids.isEmpty else { return }
        snoozeDateTargets = ids
    }

    /// Archives the conversations until `wakeAt`, with Undo.
    @discardableResult
    func snooze(_ keys: Set<ThreadKey>? = nil, until wakeAt: Date) -> Task<Void, Never>? {
        snoozeDateTargets = nil
        let keys = keys ?? selectedThreadIDs
        let ids = Self.threadIDs(keys)
        guard let keeper = snoozeKeeper, !ids.isEmpty else { return nil }
        guard wakeAt > .now else {
            notice = Notice(message: "Choose a time later than now.", isError: true)
            return nil
        }
        if !search.isActive, selectedLabelID == SystemLabel.inbox {
            selectThread(after: keys)
        }
        let subject = ids.count == 1 ? "Conversation" : "\(ids.count) conversations"
        let time = wakeAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return queueUndoable(
            "Snooze",
            confirmation: "\(subject) snoozed until \(time)",
            revert: { receipt in try await keeper.undoSnooze(receipt) }
        ) { _ in
            try await keeper.snooze(threadIDs: ids, until: wakeAt)
        }
    }

    /// Brings snoozed conversations back to the Inbox now.
    @discardableResult
    func unsnooze(_ keys: Set<ThreadKey>? = nil) -> Task<Void, Never>? {
        let keys = keys ?? selectedThreadIDs
        guard let keeper = snoozeKeeper, !keys.isEmpty else { return nil }
        if showsSnoozed { selectThread(after: keys) }
        let subject = keys.count == 1 ? "Conversation" : "\(keys.count) conversations"
        let ids = Self.threadIDs(keys)
        return Task {
            do {
                try await keeper.unsnooze(threadIDs: ids)
                notice = Notice(message: "\(subject) moved to the Inbox")
            } catch {
                notice = Notice(message: "Tern couldn't unsnooze that. Try again.", isError: true)
            }
        }
    }
}
