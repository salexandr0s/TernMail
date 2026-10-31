import MessageContent
import SwiftUI

/// The main window's toolbar over the conversation: triage actions, then
/// replies, in the order mail apps on the Mac use. The window's search
/// field follows them (`WorkspaceSearch`). Fixed spacers split the actions
/// into groups, since adjacent items otherwise share one glass capsule.
struct MailToolbar: CustomizableToolbarContent {
    @Bindable var mailbox: MailboxModel
    let reply: (ReplyKind) -> Void
    var isCompact = false
    /// Hidden while the window shows Calendar or the attachment library. Each
    /// group reads it here because an inner `hidden(false)` would win over one
    /// applied to the whole toolbar.
    var isVisible = true

    private var showsStandard: Bool { isVisible && !isCompact }
    private var showsCompact: Bool { isVisible && isCompact }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "mail.archive", placement: .primaryAction) {
            Button { mailbox.perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                .help("Archive").disabled(!mailbox.canArchive)
        }
        .mailToolbarVisible(isVisible)
        ToolbarItem(id: "mail.trash", placement: .primaryAction) {
            Button { mailbox.perform(.trash) } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move to Trash").disabled(!mailbox.canTrash)
        }
        .mailToolbarVisible(isVisible)
        ToolbarSpacer(.fixed, placement: .primaryAction)
            .mailToolbarVisible(isVisible)
        standardTriage
        ToolbarItem(id: "mail.compactActions", placement: .primaryAction) {
            Menu {
                readAction
                moveAction
                editLabelsAction
                snoozeMenu
                TriageControls(mailbox: mailbox)
            } label: { Label("More mail actions", systemImage: "ellipsis") }
                .menuIndicator(.hidden)
                .help("More mail actions")
                .accessibilityLabel("More mail actions")
                .popover(isPresented: isMoving, arrowEdge: .bottom) { movePicker }
                .popover(isPresented: isEditingLabels, arrowEdge: .bottom) { labelPicker }
        }
        .mailToolbarVisible(showsCompact)
        ToolbarSpacer(.fixed, placement: .primaryAction)
            .mailToolbarVisible(isVisible)
        replies
        ToolbarSpacer(.fixed, placement: .primaryAction)
            .mailToolbarVisible(showsStandard)
        ToolbarItem(id: "mail.more", placement: .primaryAction) { TriageControls(mailbox: mailbox) }
            .mailToolbarVisible(showsStandard)
    }

    private var standardTriage: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "mail.read", placement: .primaryAction) { readAction }
            ToolbarItem(id: "mail.move", placement: .primaryAction) {
                moveAction.popover(isPresented: isMoving, arrowEdge: .bottom) { movePicker }
            }
            ToolbarItem(id: "mail.labels", placement: .primaryAction) {
                editLabelsAction.popover(isPresented: isEditingLabels, arrowEdge: .bottom) { labelPicker }
            }
            ToolbarItem(id: "mail.snooze", placement: .primaryAction) { snoozeMenu }
        }
        .mailToolbarVisible(showsStandard)
    }

    private var replies: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "mail.reply", placement: .primaryAction) { replyButton(.reply, title: "Reply", symbol: "arrowshape.turn.up.left") }
                .mailToolbarVisible(showsStandard)
            ToolbarItem(id: "mail.replyAll", placement: .primaryAction) { replyButton(.replyAll, title: "Reply All", symbol: "arrowshape.turn.up.left.2") }
                .mailToolbarVisible(showsStandard)
            ToolbarItem(id: "mail.forward", placement: .primaryAction) { replyButton(.forward, title: "Forward", symbol: "arrowshape.turn.up.right") }
                .mailToolbarVisible(showsStandard)
            ToolbarItem(id: "mail.compactReplies", placement: .primaryAction) {
                Menu { replyActions.labelStyle(.titleAndIcon) } label: {
                    Label("Reply or Forward", systemImage: "arrowshape.turn.up.left")
                }
                .menuIndicator(.visible).help("Reply or Forward")
                .accessibilityLabel("Reply or Forward").disabled(!mailbox.canReply)
            }
            .mailToolbarVisible(showsCompact)
        }
    }

    private func replyButton(_ kind: ReplyKind, title: String, symbol: String) -> some View {
        Button { reply(kind) } label: { Label(title, systemImage: symbol) }
            .help(title).disabled(!mailbox.canReply)
    }

    private var readAction: some View {
        let isRead = mailbox.allRead(mailbox.selectedThreadIDs)
        return Button { mailbox.toggleRead() } label: {
            Label(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open")
        }
        .help(isRead ? "Mark as Unread" : "Mark as Read")
        .disabled(mailbox.selectedThreadIDs.isEmpty)
    }

    private var moveAction: some View {
        Button { mailbox.showMoveTo() } label: {
            Label("Move to", systemImage: "folder")
        }
        .help("Move to")
        .disabled(mailbox.selectedThreadIDs.isEmpty)
    }

    private var editLabelsAction: some View {
        Button { mailbox.showEditLabels() } label: {
            Label("Edit Labels", systemImage: "tag")
        }
        .help("Edit Labels")
        .disabled(mailbox.selectedThreadIDs.isEmpty)
    }

    private var snoozeMenu: some View {
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

    // Menu commands and context menus present these from the visible toolbar control.
    private var movePicker: some View {
        MoveToView(targets: mailbox.moveChoices, onMove: { mailbox.move(to: $0) })
    }

    @ViewBuilder private var labelPicker: some View {
        if let edit = mailbox.labelEdit {
            EditLabelsView(
                labels: mailbox.labelChoices,
                applied: edit.applied,
                onApply: { mailbox.applyLabels($0) },
                onCreateLabel: { mailbox.createLabel(named: $0, after: $1) }
            )
        }
    }

    @ViewBuilder
    private var replyActions: some View {
        replyButton(.reply, title: "Reply", symbol: "arrowshape.turn.up.left")
        replyButton(.replyAll, title: "Reply All", symbol: "arrowshape.turn.up.left.2")
        replyButton(.forward, title: "Forward", symbol: "arrowshape.turn.up.right")
    }

    private var isEditingLabels: Binding<Bool> {
        $mailbox.labelEdit.isPresent()
    }

    private var isMoving: Binding<Bool> {
        $mailbox.moveTargets.isPresent()
    }
}

/// Suppresses an item without removing its customization definition.
extension CustomizableToolbarContent {
    func mailToolbarVisible(_ visible: Bool) -> some CustomizableToolbarContent {
        hidden(!visible)
    }
}
