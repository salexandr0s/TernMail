import MailStore
import SwiftUI

/// Menu choices describe the clicked mail, including search results and detached readers.
struct MailContextState {
    let labels: [Set<String>]

    init(labels: [Set<String>]) { self.labels = labels }

    init(items: [MessageListItem]) {
        labels = items.flatMap { item in
            item.messages.isEmpty ? [item.labels] : item.messages.map(\.labels)
        }
    }

    var containsDrafts: Bool { labels.contains { $0.contains(SystemLabel.draft) } }
    var allSpam: Bool { allHave(SystemLabel.spam) }
    var allImportant: Bool { allHave(SystemLabel.important) }
    var canArchive: Bool { labels.contains { $0.contains(SystemLabel.inbox) } }
    var canTrash: Bool { !labels.isEmpty && !allHave(SystemLabel.trash) }
    var canMoveToInbox: Bool {
        !containsDrafts && labels.contains {
            !$0.contains(SystemLabel.inbox) || $0.contains(SystemLabel.trash) || $0.contains(SystemLabel.spam)
        }
    }
    var permanentDeletionLabel: String? {
        if allHave(SystemLabel.trash) { return SystemLabel.trash }
        if allSpam { return SystemLabel.spam }
        return nil
    }

    private func allHave(_ label: String) -> Bool {
        !labels.isEmpty && labels.allSatisfy { $0.contains(label) }
    }
}

struct MailContextTriageItems: View {
    let mailbox: MailboxModel
    let rows: Set<MailListRowID>
    let state: MailContextState
    var allowsPermanentDeletion = true
    var unsnoozes = false
    var onMoveToInbox: (() -> Void)? = nil

    var body: some View {
        if state.canArchive {
            Button("Archive", systemImage: "archivebox") { mailbox.performListAction(.archive, rows: rows) }
        }
        if state.canTrash {
            Button("Move to Trash", systemImage: "trash") { mailbox.performListAction(.trash, rows: rows) }
        }
        if state.canMoveToInbox {
            Button("Move to Inbox", systemImage: "tray") {
                if let onMoveToInbox { onMoveToInbox() }
                else { mailbox.moveRowsToInbox(rows, unsnooze: unsnoozes) }
            }
        }
        if !state.containsDrafts {
            Button(state.allSpam ? "Not Spam" : "Report Spam", systemImage: state.allSpam ? "checkmark.shield" : "xmark.bin") {
                mailbox.triage.perform(state.allSpam ? .notSpam : .spam, targets: mailbox.actionTargets(forRows: rows))
            }
            Button(state.allImportant ? "Mark as Not Important" : "Mark as Important", systemImage: "exclamationmark") {
                mailbox.triage.perform(state.allImportant ? .notImportant : .important, targets: mailbox.actionTargets(forRows: rows))
            }
        }
        if allowsPermanentDeletion, let labelID = state.permanentDeletionLabel {
            Button("Delete Forever…", systemImage: "trash.slash", role: .destructive) {
                Task { await mailbox.triage.preparePermanentDeletion(in: .combined(labelID), forRows: rows) }
            }
            .disabled(mailbox.triage.isPreparing || mailbox.triage.isDeleting)
        }
    }
}
