import Foundation
import MailStore
import SyncEngine

/// Snooze from the toolbar, the context menu and the Message menu. Tern
/// keeps snoozes itself: Gmail sees an archive, then a return to the Inbox.
extension MailboxModel {
    /// Snoozing archives, so it's offered where Archive is.
    var canSnooze: Bool {
        offersArchive && !selectedThreadIDs.isEmpty
            && selectedThreadIDs.allSatisfy { account(id: $0.accountID)?.snoozeKeeper != nil }
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
        account(id: thread.accountID)?.wokenThreadIDs.contains(thread.id) ?? false
    }

    /// Choose Date & Time, from the menus.
    func showSnoozeDate(for keys: Set<ThreadKey>? = nil) {
        if !listPreferences.conversations {
            showSnoozeDate(forRows: selectedMessageRows.filter { keys?.contains($0.threadKey) ?? true })
            return
        }
        let ids = keys ?? selectedThreadIDs
        guard !ids.isEmpty, ids.allSatisfy({ account(id: $0.accountID)?.snoozeKeeper != nil }) else { return }
        snoozeDateTargets = ids
        snoozeRowTargets = nil
    }

    /// Archives the conversations until `wakeAt`, with Undo.
    @discardableResult
    func snooze(_ keys: Set<ThreadKey>? = nil, until wakeAt: Date) -> Task<Void, Never>? {
        if let rows = snoozeRowTargets {
            return snoozeRows(rows, until: wakeAt)
        }
        if !listPreferences.conversations {
            return snoozeRows(selectedMessageRows.filter { keys?.contains($0.threadKey) ?? true }, until: wakeAt)
        }
        snoozeDateTargets = nil
        let keys = keys ?? selectedThreadIDs
        guard !keys.isEmpty else { return nil }
        guard wakeAt > .now else {
            notice = Notice(message: "Choose a time later than now.", isError: true)
            return nil
        }
        if !search.isActive, selectedLabelID == SystemLabel.inbox {
            selectThread(after: keys)
        }
        let subject = keys.count == 1 ? "Conversation" : "\(keys.count) conversations"
        let time = wakeAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return queueUndoable(
            "Snooze",
            confirmation: "\(subject) snoozed until \(time)",
            for: keys,
            revert: { owner, receipt in try await owner.snoozeKeeper?.undoSnooze(receipt) }
        ) { owner, ids in
            try await owner.snoozeKeeper?.snooze(threadIDs: ids, until: wakeAt)
        }
    }

    /// Brings snoozed conversations back to the Inbox now.
    @discardableResult
    func unsnooze(_ keys: Set<ThreadKey>? = nil) -> Task<Void, Never>? {
        if !listPreferences.conversations {
            return unsnoozeRows(selectedMessageRows.filter { keys?.contains($0.threadKey) ?? true })
        }
        let keys = keys ?? selectedThreadIDs
        let groups = Dictionary(grouping: keys, by: \.accountID).compactMap { accountID, keys in
            account(id: accountID)?.snoozeKeeper.map { ($0, Self.threadIDs(Set(keys))) }
        }
        guard !groups.isEmpty else { return nil }
        if showsSnoozed { selectThread(after: keys) }
        let subject = keys.count == 1 ? "Conversation" : "\(keys.count) conversations"
        return Task {
            do {
                for (keeper, ids) in groups {
                    try await keeper.unsnooze(threadIDs: ids)
                }
                notice = Notice(message: "\(subject) moved to the Inbox")
            } catch {
                notice = Notice(message: "Couldn't return this mail to the Inbox. Try again.", isError: true)
            }
        }
    }
}
