import Foundation
import GmailAPI
import MailStore
import SyncEngine

/// Label changes from the sidebar, Edit Labels, Move to and the menus.
/// Labels belong to one account, so each command acts in one account and
/// goes through its engine's queue.
extension MailboxModel {
    /// Edit Labels for some conversations in one account, with each one's
    /// labels when it opened.
    struct LabelEdit: Equatable {
        let accountID: String
        let threadIDs: Set<ThreadKey>
        let applied: [Set<String>]
        var messageIDs: [String]? = nil
    }

    /// What the label sheet edits.
    struct LabelEditorRequest: Identifiable {
        enum Kind {
            /// A new label, added to these conversations once queued.
            case new(applyingTo: Set<ThreadKey>)
            case edit(LabelRecord)
        }

        let id = UUID()
        let accountID: String
        let kind: Kind
        let draft: LabelEditorSheet.Draft
        var messageIDs: [String]? = nil
    }

    // MARK: Reading

    /// The account the open picker or sheet acts in, otherwise the current one.
    private var labelAccount: AccountMailbox {
        let accountID = labelEdit?.accountID ?? labelEditor?.accountID ?? moveTargets?.first?.accountID
        return accountID.flatMap { account(id: $0) } ?? currentAccount
    }

    private var labelAccountUserLabels: [LabelRecord] {
        labelAccount.labels.filter { !$0.isSystem }
    }

    /// User labels as the pickers list them.
    var labelChoices: [LabelChoice] {
        labelAccountUserLabels.map {
            LabelChoice(
                id: $0.id, name: $0.name, backgroundColor: $0.backgroundColor,
                systemImage: LabelAppearance.shared.icon(for: $0)
            )
        }
    }

    /// Move to offers the Inbox and the user labels, less the mailbox shown.
    var moveChoices: [LabelChoice] {
        let inbox = LabelChoice(id: SystemLabel.inbox, name: "Inbox", systemImage: "tray")
        return ([inbox] + labelChoices).filter { $0.id != moveSourceLabelID }
    }

    /// Full names of the labels `label` may be nested under: any other user
    /// label outside its own branch.
    func parentChoices(for label: LabelRecord?) -> [String] {
        labelAccountUserLabels.map(\.name).filter { name in
            guard let label else { return true }
            return name != label.name && !name.hasPrefix(label.name + "/")
        }
    }

    /// Why Gmail would refuse `name`, or nil.
    func labelNameProblem(_ name: String, renaming labelID: String?) -> String? {
        LabelRules.problem(with: name, among: labelAccount.labels, renaming: labelID).map(Self.message)
    }

    // MARK: Opening

    func showEditLabels(for keys: Set<ThreadKey>? = nil) {
        if !listPreferences.conversations {
            showEditLabels(forRows: selectedMessageRows.filter { keys?.contains($0.threadKey) ?? true })
            return
        }
        let ids = keys ?? selectedThreadIDs
        guard let accountID = oneAccount(of: ids, or: "Choose conversations from one account to edit their labels.")
        else { return }
        Task {
            do {
                let applied = try await cache.read { tx in
                    try ids.sorted().map { key in
                        try tx.currentLabels(threadID: key.threadID, accountID: key.accountID)
                            .values.reduce(into: Set<String>()) { $0.formUnion($1) }
                    }
                }
                labelEdit = LabelEdit(accountID: accountID, threadIDs: ids, applied: applied)
            } catch {
                notice = Notice(message: "Couldn't load labels for these conversations.", isError: true)
            }
        }
    }

    func showMoveTo(for keys: Set<ThreadKey>? = nil) {
        if !listPreferences.conversations {
            showMoveTo(forRows: selectedMessageRows.filter { keys?.contains($0.threadKey) ?? true })
            return
        }
        let ids = keys ?? selectedThreadIDs
        guard oneAccount(of: ids, or: "Choose conversations from one account to move them.") != nil else { return }
        moveTargets = ids
        moveMessageTargets = nil
        moveSourceLabelID = search.isActive ? nil : selectedLabelID ?? SystemLabel.inbox
    }

    func showEditLabels(forRows rows: Set<MailListRowID>) {
        let keys = Set(rows.map(\.threadKey))
        guard let accountID = oneAccount(of: keys, or: "Choose mail from one account to edit its labels.") else { return }
        let messageIDs = rows.compactMap(\.messageID).sorted()
        guard messageIDs.count == rows.count else {
            if messageIDs.isEmpty { showEditLabels(for: keys) }
            return
        }
        let chosen = Set(messageIDs)
        let entries = listEntries.filter { $0.message.accountID == accountID && chosen.contains($0.message.id) }
        guard entries.count == chosen.count else { return }
        labelEdit = LabelEdit(accountID: accountID, threadIDs: keys, applied: entries.map(\.labels), messageIDs: messageIDs)
    }

    func showMoveTo(forRows rows: Set<MailListRowID>) {
        let keys = Set(rows.map(\.threadKey))
        guard oneAccount(of: keys, or: "Choose mail from one account to move it.") != nil else { return }
        let messages = rows.compactMap(\.messageID).sorted()
        guard messages.isEmpty || messages.count == rows.count else { return }
        moveTargets = keys
        moveMessageTargets = messages.isEmpty ? nil : messages
        moveSourceLabelID = search.isActive ? nil : selectedLabelID ?? SystemLabel.inbox
    }

    /// New Label, from the sidebar, the menu or Edit Labels' Create Label.
    /// It goes in `accountID`, else the account of the conversations it's
    /// for, else the current one.
    func showNewLabel(named name: String = "", applyingTo threadIDs: Set<ThreadKey> = [], in accountID: String? = nil, messageIDs: [String]? = nil) {
        labelEdit = nil
        labelEditor = LabelEditorRequest(
            accountID: accountID ?? threadIDs.first?.accountID ?? currentAccount.account.id,
            kind: .new(applyingTo: threadIDs),
            draft: .init(name: name, parent: nil, color: nil), messageIDs: messageIDs
        )
    }

    func showEditLabel(_ label: LabelRecord) {
        let parent = (account(id: label.accountID)?.labels ?? [])
            .filter { !$0.isSystem }
            .map(\.name)
            .filter { label.name.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        let name = parent.map { String(label.name.dropFirst($0.count + 1)) } ?? label.name
        labelEditor = LabelEditorRequest(
            accountID: label.accountID,
            kind: .edit(label),
            draft: .init(
                name: name, parent: parent, color: Self.color(of: label),
                icon: LabelAppearance.shared.icon(for: label)
            )
        )
    }

    // MARK: Changing

    /// Saves the label sheet.
    func saveLabel(_ draft: LabelEditorSheet.Draft, for request: LabelEditorRequest) {
        labelEditor = nil
        guard let owner = account(id: request.accountID) else { return }
        let name = draft.fullName
        let cache = cache
        switch request.kind {
        case .new(let threadIDs):
            let ids = Self.threadIDs(threadIDs)
            queueUndoable("New Label", in: owner) { engine in
                let receipt = try await engine.createLabel(named: name, color: draft.color)
                if let labelID = receipt.labelID {
                    LabelAppearance.shared.setIcon(draft.icon, labelID: labelID, accountID: request.accountID)
                    await LabelAppearance.shared.reconcile(using: cache)
                }
                // These wait for Gmail's ID, and undoing the new label drops them.
                if !ids.isEmpty, let labelID = receipt.labelID {
                    let target: MailActionTarget = request.messageIDs.map { .messages($0) } ?? .threads(ids)
                    _ = try await engine.editLabels(target: target, add: [labelID], remove: [])
                }
                return receipt
            }
        case .edit(let label):
            if draft.icon != LabelAppearance.shared.icon(for: label) {
                LabelAppearance.shared.setIcon(draft.icon, labelID: label.id, accountID: label.accountID)
                Task { await LabelAppearance.shared.reconcile(using: cache) }
            }
            if name != label.name {
                queueUndoable("Rename Label", in: owner) { engine in try await engine.renameLabel(label.id, to: name) }
            }
            if draft.color != Self.color(of: label) {
                queueUndoable("Change Label Color", in: owner) { engine in
                    try await engine.setLabelColor(label.id, to: draft.color)
                }
            }
        }
    }

    /// Deletes the label waiting for confirmation. Gmail can't restore it,
    /// so there's no undo.
    func deleteConfirmedLabel() {
        guard let label = labelToDelete else { return }
        labelToDelete = nil
        guard let engine = account(id: label.accountID)?.engine else { return }
        Task {
            do {
                try await engine.deleteLabel(label.id)
            } catch {
                notice = Notice(message: Self.failureMessage(error), isError: true)
            }
        }
    }

    /// Edit Labels' Create Label: applies the boxes already changed, as
    /// Apply would, then opens New Label for the same conversations.
    @discardableResult
    func createLabel(named name: String, after change: LabelSelection.Change) -> Task<Void, Never>? {
        guard let edit = labelEdit else { return nil }
        let applying = applyLabels(change)
        showNewLabel(named: name, applyingTo: edit.threadIDs, messageIDs: edit.messageIDs)
        return applying
    }

    /// Applies Edit Labels to the conversations it opened for.
    @discardableResult
    func applyLabels(_ change: LabelSelection.Change) -> Task<Void, Never>? {
        guard let edit = labelEdit else { return nil }
        labelEdit = nil
        guard !change.isEmpty else { return nil }
        return queueUndoable("Edit Labels", for: edit.threadIDs) { owner, ids in
            let target: MailActionTarget = edit.messageIDs.map { .messages($0) } ?? .threads(ids)
            return try await owner.engine.editLabels(target: target, add: change.add.sorted(), remove: change.remove.sorted())
        }
    }

    /// A label chip's remove button: takes one conversation out of a user label.
    @discardableResult
    func removeLabel(_ labelID: String, from key: ThreadKey) -> Task<Void, Never>? {
        if !search.isActive, selectedLabelID == labelID { selectThread(after: [key]) }
        return queueUndoable("Remove Label", for: [key]) { owner, ids in
            try await owner.engine.editLabels(threadIDs: ids, add: [], remove: [labelID])
        }
    }

    /// Reader menus keep their message target even when the main list changes.
    @discardableResult
    func setLabel(_ labelID: String, applied: Bool, on message: MessageDetail) -> Task<Void, Never>? {
        guard let owner = account(id: message.record.accountID),
              owner.labels.contains(where: { $0.id == labelID && !$0.isSystem }) else { return nil }
        return queueUndoable(applied ? "Add Label" : "Remove Label", in: owner) { engine in
            try await engine.editLabels(target: .messages([message.id]), add: applied ? [labelID] : [],
                                        remove: applied ? [] : [labelID])
        }
    }

    @discardableResult
    func moveMessage(_ message: MessageDetail, to labelID: String) -> Task<Void, Never>? {
        guard let owner = account(id: message.record.accountID),
              labelID == SystemLabel.inbox || owner.labels.contains(where: { $0.id == labelID && !$0.isSystem }) else { return nil }
        return Task {
            do {
                let snoozed = try await cache.read { tx -> Bool? in
                    let accountID = message.record.accountID
                    guard try tx.message(id: message.id, accountID: accountID)?.threadID == message.record.threadID else { return nil }
                    return try Self.hasSnooze(.messages([message.id]), accountID: accountID, in: tx)
                }
                guard account(id: message.record.accountID) === owner, !Task.isCancelled else { return }
                guard let snoozed else {
                    notice = Notice(message: "This message is no longer available.", isError: true)
                    return
                }
                if snoozed {
                    guard labelID == SystemLabel.inbox else {
                        notice = Notice(message: "Move this mail to Inbox to end its snooze before moving it to a folder. Use Labels to add a label while keeping the snooze.")
                        return
                    }
                    guard let keeper = owner.snoozeKeeper else {
                        notice = Notice(message: "Couldn't return this mail to the Inbox. Try again.", isError: true)
                        return
                    }
                    try await keeper.unsnooze(target: .messages([message.id]))
                    notice = Notice(message: "Message moved to the Inbox")
                    return
                }
                await queueUndoable("Move Message", in: owner) { engine in
                    try await engine.editLabels(target: .messages([message.id]), add: [labelID],
                                                remove: [SystemLabel.inbox, SystemLabel.trash, SystemLabel.spam])
                }?.value
            } catch {
                guard account(id: message.record.accountID) === owner, !(error is CancellationError) else { return }
                notice = Notice(message: "Couldn't move this message. Try again.", isError: true)
            }
        }
    }

    /// Moves the conversations Move to opened for, out of the mailbox shown.
    @discardableResult
    func move(to labelID: String) -> Task<Void, Never>? {
        guard let targets = moveTargets else { return nil }
        let labelName = labelAccount.labels.first { $0.id == labelID }?.name
        let messageIDs = moveMessageTargets
        let from = moveSourceLabelID ?? SystemLabel.inbox
        moveTargets = nil
        moveMessageTargets = nil
        if from == Self.snoozedID, labelID != SystemLabel.inbox {
            notice = Notice(message: "Move this mail to Inbox to end its snooze before moving it to a folder. Use Edit Labels to add a label while keeping the snooze.")
            return nil
        }
        let title = labelID == SystemLabel.inbox ? "Inbox" : labelName ?? "the label"
        let subject = targets.count == 1 ? "Conversation" : "\(targets.count) conversations"
        if !search.isActive, selectedLabelID == from {
            if let messageIDs {
                selectRow(after: selectedMessageRows.filter { targets.contains($0.threadKey) && messageIDs.contains($0.messageID ?? "") })
            } else { selectThread(after: targets) }
        }
        if from == Self.snoozedID {
            guard let accountID = targets.first?.accountID, let keeper = account(id: accountID)?.snoozeKeeper else { return nil }
            let target: MailActionTarget = messageIDs.map { .messages($0) } ?? .threads(Self.threadIDs(targets))
            return Task {
                do {
                    try await keeper.unsnooze(target: target)
                    notice = Notice(message: "\(subject) moved to the Inbox")
                } catch { notice = Notice(message: "Couldn't return this mail to the Inbox. Try again.", isError: true) }
            }
        }
        return queueUndoable("Move", confirmation: "\(subject) moved to “\(title)”", for: targets) { owner, ids in
            let target: MailActionTarget = messageIDs.map { .messages($0) } ?? .threads(ids)
            if labelID != SystemLabel.inbox {
                let accountID = owner.account.id
                let snoozed = try await self.cache.read { tx in
                    try Self.hasSnooze(target, accountID: accountID, in: tx)
                }
                if snoozed {
                    self.notice = Notice(message: "Move this mail to Inbox to end its snooze before moving it to a folder. Use Edit Labels to add a label while keeping the snooze.")
                    return nil
                }
            }
            let sourceLabel = owner.labels.first { $0.id == from && !$0.isSystem }?.id
            let remove = [SystemLabel.inbox, SystemLabel.trash, SystemLabel.spam] + (sourceLabel.map { [$0] } ?? [])
            return try await owner.engine.editLabels(target: target, add: [labelID], remove: remove)
        }
    }

    nonisolated static func hasSnooze(_ target: MailActionTarget, accountID: String, in tx: CacheTransaction) throws -> Bool {
        let threads = try tx.snoozeHolds(accountID: accountID)
        let messages = try tx.messageSnoozeHolds(accountID: accountID)
        switch target {
        case .threads(let ids):
            let chosen = Set(ids)
            return ids.contains { threads[$0] != nil } || messages.contains { chosen.contains($0.threadID) }
        case .messages(let ids):
            let chosen = Set(ids)
            if messages.contains(where: { chosen.contains($0.messageID) }) { return true }
            return try ids.contains { id in
                guard let message = try tx.message(id: id, accountID: accountID) else { return false }
                return threads[message.threadID] != nil
            }
        }
    }

    /// The one account `keys` belong to. Shows `refusal` when they span accounts.
    private func oneAccount(of keys: Set<ThreadKey>, or refusal: String) -> String? {
        let owners = Set(keys.map(\.accountID))
        if owners.count > 1 { notice = Notice(message: refusal) }
        return owners.count == 1 ? owners.first : nil
    }

    // MARK: Messages

    static func failureMessage(_ error: any Error) -> String {
        switch error as? LabelChangeError {
        case .name(let problem)?: message(problem)
        case .notAUserLabel?: "This label is missing or managed by Gmail."
        case nil: "Couldn't save this change. Try again."
        }
    }

    private static func message(_ problem: LabelRules.NameProblem) -> String {
        switch problem {
        case .empty: "Enter a name for the label."
        case .reserved: "Gmail reserves this label name."
        case .taken: "A label with this name already exists."
        }
    }

    private static func color(of label: LabelRecord) -> LabelColor? {
        guard let background = label.backgroundColor else { return nil }
        if let text = label.textColor, let color = LabelColor(backgroundColor: background, textColor: text) { return color }
        return LabelColor(backgroundColor: background)
    }
}
