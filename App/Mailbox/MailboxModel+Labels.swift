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
        labelAccountUserLabels.map { LabelChoice(id: $0.id, name: $0.name, backgroundColor: $0.backgroundColor) }
    }

    /// Move to offers the Inbox and the user labels, less the mailbox shown.
    var moveChoices: [LabelChoice] {
        let inbox = LabelChoice(id: SystemLabel.inbox, name: "Inbox", systemImage: "tray")
        return ([inbox] + labelChoices).filter { search.isActive || $0.id != selectedLabelID }
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
                notice = Notice(message: "Tern couldn't read these conversations' labels.", isError: true)
            }
        }
    }

    func showMoveTo(for keys: Set<ThreadKey>? = nil) {
        let ids = keys ?? selectedThreadIDs
        guard oneAccount(of: ids, or: "Choose conversations from one account to move them.") != nil else { return }
        moveTargets = ids
    }

    /// New Label, from the sidebar, the menu or Edit Labels' Create Label.
    /// It goes in the account of the conversations it's for, otherwise the current one.
    func showNewLabel(named name: String = "", applyingTo threadIDs: Set<ThreadKey> = []) {
        labelEdit = nil
        labelEditor = LabelEditorRequest(
            accountID: threadIDs.first?.accountID ?? currentAccount.account.id,
            kind: .new(applyingTo: threadIDs),
            draft: .init(name: name, parent: nil, color: nil)
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
            draft: .init(name: name, parent: parent, color: Self.color(of: label))
        )
    }

    // MARK: Changing

    /// Saves the label sheet.
    func saveLabel(_ draft: LabelEditorSheet.Draft, for request: LabelEditorRequest) {
        labelEditor = nil
        guard let owner = account(id: request.accountID) else { return }
        let name = draft.fullName
        switch request.kind {
        case .new(let threadIDs):
            let ids = Self.threadIDs(threadIDs)
            queueUndoable("New Label", in: owner) { engine in
                let receipt = try await engine.createLabel(named: name, color: draft.color)
                // These wait for Gmail's ID, and undoing the new label drops them.
                if !ids.isEmpty, let labelID = receipt.labelID {
                    _ = try await engine.editLabels(threadIDs: ids, add: [labelID], remove: [])
                }
                return receipt
            }
        case .edit(let label):
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

    /// Applies Edit Labels to the conversations it opened for.
    @discardableResult
    func applyLabels(_ change: LabelSelection.Change) -> Task<Void, Never>? {
        guard let edit = labelEdit else { return nil }
        labelEdit = nil
        guard !change.isEmpty else { return nil }
        return queueUndoable("Edit Labels", for: edit.threadIDs) { owner, ids in
            try await owner.engine.editLabels(threadIDs: ids, add: change.add.sorted(), remove: change.remove.sorted())
        }
    }

    /// Moves the conversations Move to opened for, out of the mailbox shown.
    @discardableResult
    func move(to labelID: String) -> Task<Void, Never>? {
        guard let targets = moveTargets else { return nil }
        let labelName = labelAccount.labels.first { $0.id == labelID }?.name
        moveTargets = nil
        let title = labelID == SystemLabel.inbox ? "Inbox" : labelName ?? "the label"
        let subject = targets.count == 1 ? "Conversation" : "\(targets.count) conversations"
        // Search results come from any mailbox, so they leave the Inbox.
        let from = search.isActive ? SystemLabel.inbox : selectedLabelID ?? SystemLabel.inbox
        if !search.isActive { selectThread(after: targets) }
        return queueUndoable("Move", confirmation: "\(subject) moved to “\(title)”", for: targets) { owner, ids in
            try await owner.engine.move(threadIDs: ids, to: labelID, from: from)
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
        case .notAUserLabel?: "Tern couldn't find that label."
        case nil: "Tern couldn't save that change."
        }
    }

    private static func message(_ problem: LabelRules.NameProblem) -> String {
        switch problem {
        case .empty: "Enter a name for the label."
        case .reserved: "Gmail keeps this name for its own labels."
        case .taken: "A label with this name already exists."
        }
    }

    private static func color(of label: LabelRecord) -> LabelColor? {
        guard let background = label.backgroundColor else { return nil }
        if let text = label.textColor, let color = LabelColor(backgroundColor: background, textColor: text) { return color }
        return LabelColor(backgroundColor: background)
    }
}
