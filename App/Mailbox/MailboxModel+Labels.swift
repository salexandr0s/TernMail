import Foundation
import GmailAPI
import MailStore
import SyncEngine

/// Label changes from the sidebar, Edit Labels, Move to and the menus.
/// Every change goes through the engine's queue.
extension MailboxModel {
    /// Edit Labels for some conversations, with each one's labels when it opened.
    struct LabelEdit: Equatable {
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
        let kind: Kind
        let draft: LabelEditorSheet.Draft
    }

    // MARK: Reading

    /// User labels as the pickers list them.
    var labelChoices: [LabelChoice] {
        userLabels.map { LabelChoice(id: $0.id, name: $0.name, backgroundColor: $0.backgroundColor) }
    }

    /// Move to offers the Inbox and the user labels, less the mailbox shown.
    var moveChoices: [LabelChoice] {
        let inbox = LabelChoice(id: SystemLabel.inbox, name: "Inbox", systemImage: "tray")
        return ([inbox] + labelChoices).filter { search.isActive || $0.id != selectedLabelID }
    }

    /// Full names of the labels `label` may be nested under: any other user
    /// label outside its own branch.
    func parentChoices(for label: LabelRecord?) -> [String] {
        userLabels.map(\.name).filter { name in
            guard let label else { return true }
            return name != label.name && !name.hasPrefix(label.name + "/")
        }
    }

    /// Why Gmail would refuse `name`, or nil.
    func labelNameProblem(_ name: String, renaming labelID: String?) -> String? {
        LabelRules.problem(with: name, among: labels, renaming: labelID).map(Self.message)
    }

    // MARK: Opening

    func showEditLabels(for keys: Set<ThreadKey>? = nil) {
        let ids = keys ?? selectedThreadIDs
        guard !ids.isEmpty else { return }
        Task {
            do {
                let applied = try await cache.read { tx in
                    try ids.sorted().map { key in
                        try tx.currentLabels(threadID: key.threadID, accountID: key.accountID)
                            .values.reduce(into: Set<String>()) { $0.formUnion($1) }
                    }
                }
                labelEdit = LabelEdit(threadIDs: ids, applied: applied)
            } catch {
                notice = Notice(message: "Tern couldn't read these conversations' labels.", isError: true)
            }
        }
    }

    func showMoveTo(for keys: Set<ThreadKey>? = nil) {
        let ids = keys ?? selectedThreadIDs
        guard !ids.isEmpty else { return }
        moveTargets = ids
    }

    /// New Label, from the sidebar, the menu or Edit Labels' Create Label.
    func showNewLabel(named name: String = "", applyingTo threadIDs: Set<ThreadKey> = []) {
        labelEdit = nil
        labelEditor = LabelEditorRequest(
            kind: .new(applyingTo: threadIDs),
            draft: .init(name: name, parent: nil, color: nil)
        )
    }

    func showEditLabel(_ label: LabelRecord) {
        let parent = userLabels
            .map(\.name)
            .filter { label.name.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        let name = parent.map { String(label.name.dropFirst($0.count + 1)) } ?? label.name
        labelEditor = LabelEditorRequest(
            kind: .edit(label),
            draft: .init(name: name, parent: parent, color: Self.color(of: label))
        )
    }

    // MARK: Changing

    /// Saves the label sheet.
    func saveLabel(_ draft: LabelEditorSheet.Draft, for request: LabelEditorRequest) {
        labelEditor = nil
        let name = draft.fullName
        switch request.kind {
        case .new(let threadIDs):
            let ids = Self.threadIDs(threadIDs)
            queueUndoable("New Label") { engine in
                let receipt = try await engine.createLabel(named: name, color: draft.color)
                // These wait for Gmail's ID, and undoing the new label drops them.
                if !ids.isEmpty, let labelID = receipt.labelID {
                    _ = try await engine.editLabels(threadIDs: ids, add: [labelID], remove: [])
                }
                return receipt
            }
        case .edit(let label):
            if name != label.name {
                queueUndoable("Rename Label") { engine in try await engine.renameLabel(label.id, to: name) }
            }
            if draft.color != Self.color(of: label) {
                queueUndoable("Change Label Color") { engine in try await engine.setLabelColor(label.id, to: draft.color) }
            }
        }
    }

    /// Deletes the label waiting for confirmation. Gmail can't restore it,
    /// so there's no undo.
    func deleteConfirmedLabel() {
        guard let label = labelToDelete else { return }
        labelToDelete = nil
        let engine = engine
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
        let ids = Self.threadIDs(edit.threadIDs)
        return queueUndoable("Edit Labels") { engine in
            try await engine.editLabels(threadIDs: ids, add: change.add.sorted(), remove: change.remove.sorted())
        }
    }

    /// Moves the conversations Move to opened for, out of the mailbox shown.
    @discardableResult
    func move(to labelID: String) -> Task<Void, Never>? {
        guard let targets = moveTargets else { return nil }
        moveTargets = nil
        let ids = Self.threadIDs(targets)
        let title = labelID == SystemLabel.inbox ? "Inbox" : label(id: labelID)?.name ?? "the label"
        let subject = ids.count == 1 ? "Conversation" : "\(ids.count) conversations"
        // Search results come from any mailbox, so they leave the Inbox.
        let from = search.isActive ? SystemLabel.inbox : selectedLabelID ?? SystemLabel.inbox
        if !search.isActive { selectThread(after: targets) }
        return queueUndoable("Move", confirmation: "\(subject) moved to “\(title)”") { engine in
            try await engine.move(threadIDs: ids, to: labelID, from: from)
        }
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
