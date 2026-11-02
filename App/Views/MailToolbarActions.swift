import MessageContent
import SwiftUI

/// Selection-dependent reads belong to these View bodies, so updating an
/// action doesn't invalidate the toolbar's customization declarations.
enum MailToolbarActions {
    struct Archive: View {
        let mailbox: MailboxModel

        var body: some View {
            Button { mailbox.perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                .help("Archive").disabled(!mailbox.canArchive)
        }
    }

    struct Trash: View {
        let mailbox: MailboxModel

        var body: some View {
            Button { mailbox.perform(.trash) } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move to Trash").disabled(!mailbox.canTrash)
        }
    }

    struct Read: View {
        let mailbox: MailboxModel

        var body: some View {
            let isRead = mailbox.allRead(mailbox.selectedThreadIDs)
            Button { mailbox.toggleRead() } label: {
                Label(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open")
            }
            .help(isRead ? "Mark as Unread" : "Mark as Read")
            .disabled(mailbox.selectedThreadIDs.isEmpty)
        }
    }

    // Menu commands and context menus present these from the visible toolbar control.
    struct Move: View {
        @Bindable var mailbox: MailboxModel

        var body: some View {
            MoveButton(mailbox: mailbox)
                .popover(isPresented: $mailbox.moveTargets.isPresent(), arrowEdge: .bottom) {
                    MovePicker(mailbox: mailbox)
                }
        }
    }

    struct Labels: View {
        @Bindable var mailbox: MailboxModel

        var body: some View {
            LabelsButton(mailbox: mailbox)
                .popover(isPresented: $mailbox.labelEdit.isPresent(), arrowEdge: .bottom) {
                    LabelPicker(mailbox: mailbox)
                }
        }
    }

    struct Snooze: View {
        let mailbox: MailboxModel

        var body: some View {
            Menu {
                SnoozeMenuItems(
                    onSnooze: { mailbox.snooze(until: $0) },
                    onChooseDate: { mailbox.showSnoozeDate() }
                )
                if mailbox.showsSnoozed {
                    Divider()
                    Button("Unsnooze", systemImage: "clock.arrow.circlepath") { mailbox.unsnooze() }
                        .labelStyle(.titleAndIcon)
                }
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Snooze")
            .help("Snooze")
            .disabled(!mailbox.canSnooze)
        }
    }

    struct Reply: View {
        @FocusedValue(\.selectedMailQuote) private var selectedQuote
        let mailbox: MailboxModel
        let kind: ReplyKind
        let title: String
        let symbol: String
        let reply: (ReplyKind, SelectedMailQuote?) -> Void

        var body: some View {
            Button { reply(kind, selectedQuote) } label: { Label(title, systemImage: symbol) }
                .help(title).disabled(!mailbox.canReply)
        }
    }

    struct CompactActions: View {
        @Bindable var mailbox: MailboxModel
        let foldsReplies: Bool
        let reply: (ReplyKind, SelectedMailQuote?) -> Void

        var body: some View {
            Menu {
                Read(mailbox: mailbox)
                MoveButton(mailbox: mailbox)
                LabelsButton(mailbox: mailbox)
                Snooze(mailbox: mailbox)
                TriageControls(mailbox: mailbox)
                if foldsReplies {
                    Divider()
                    Group {
                        Reply(mailbox: mailbox, kind: .reply, title: "Reply", symbol: "arrowshape.turn.up.left", reply: reply)
                        Reply(mailbox: mailbox, kind: .replyAll, title: "Reply All", symbol: "arrowshape.turn.up.left.2", reply: reply)
                        Reply(mailbox: mailbox, kind: .forward, title: "Forward", symbol: "arrowshape.turn.up.right", reply: reply)
                    }
                    .labelStyle(.titleAndIcon)
                }
            } label: { Label("More mail actions", systemImage: "ellipsis") }
                .menuIndicator(.hidden)
                .help("More mail actions")
                .accessibilityLabel("More mail actions")
                .popover(isPresented: $mailbox.moveTargets.isPresent(), arrowEdge: .bottom) {
                    MovePicker(mailbox: mailbox)
                }
                .popover(isPresented: $mailbox.labelEdit.isPresent(), arrowEdge: .bottom) {
                    LabelPicker(mailbox: mailbox)
                }
        }
    }

    struct CompactReplies: View {
        @FocusedValue(\.selectedMailQuote) private var selectedQuote
        let mailbox: MailboxModel
        let reply: (ReplyKind, SelectedMailQuote?) -> Void

        var body: some View {
            Menu { replyActions.labelStyle(.titleAndIcon) } label: {
                Label("Reply or Forward", systemImage: "arrowshape.turn.up.left")
            }
            .menuIndicator(.visible).help("Reply or Forward")
            .accessibilityLabel("Reply or Forward").disabled(!mailbox.canReply)
        }

        @ViewBuilder private var replyActions: some View {
            replyAction(.reply, title: "Reply", symbol: "arrowshape.turn.up.left")
            replyAction(.replyAll, title: "Reply All", symbol: "arrowshape.turn.up.left.2")
            replyAction(.forward, title: "Forward", symbol: "arrowshape.turn.up.right")
        }

        private func replyAction(_ kind: ReplyKind, title: String, symbol: String) -> some View {
            Button { reply(kind, selectedQuote) } label: { Label(title, systemImage: symbol) }
                .help(title).disabled(!mailbox.canReply)
        }
    }

    private struct MoveButton: View {
        let mailbox: MailboxModel

        var body: some View {
            Button { mailbox.showMoveTo() } label: {
                Label("Move to", systemImage: "folder")
            }
            .help("Move to")
            .disabled(mailbox.selectedThreadIDs.isEmpty)
        }
    }

    private struct LabelsButton: View {
        let mailbox: MailboxModel

        var body: some View {
            Button { mailbox.showEditLabels() } label: {
                Label("Edit Labels", systemImage: "tag")
            }
            .help("Edit Labels")
            .disabled(mailbox.selectedThreadIDs.isEmpty)
        }
    }

    private struct MovePicker: View {
        let mailbox: MailboxModel

        var body: some View {
            MoveToView(targets: mailbox.moveChoices, onMove: { mailbox.move(to: $0) })
        }
    }

    private struct LabelPicker: View {
        let mailbox: MailboxModel

        var body: some View {
            if let edit = mailbox.labelEdit {
                EditLabelsView(
                    labels: mailbox.labelChoices,
                    applied: edit.applied,
                    onApply: { mailbox.applyLabels($0) },
                    onCreateLabel: { mailbox.createLabel(named: $0, after: $1) }
                )
            }
        }
    }
}
