import AppKit
import MessageContent
import SwiftUI

/// The main window's toolbar over the conversation: triage actions, then
/// replies, then search, in the order mail apps on the Mac use.
struct MailToolbar: CustomizableToolbarContent {
    @Bindable var mailbox: MailboxModel
    let reply: (ReplyKind) -> Void
    var isCompact = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "mail.archive", placement: .primaryAction) {
            Button { mailbox.perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                .help("Archive").disabled(!mailbox.canArchive)
        }
        ToolbarItem(id: "mail.trash", placement: .primaryAction) {
            Button { mailbox.perform(.trash) } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move to Trash").disabled(!mailbox.canTrash)
        }
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
        .mailToolbarVisible(isCompact)
        replies
        ToolbarItem(id: "mail.search", placement: .primaryAction) {
            SearchField(search: mailbox.search, text: mailbox.search.text,
                        focusRequest: mailbox.search.fieldFocusRequest)
                .frame(width: isCompact ? Tokens.Layout.searchMinWidth : Tokens.Layout.searchWidth)
                .help("Search mail (⌥⌘F). Return searches Gmail.")
        }
        .customizationBehavior(.disabled)
        ToolbarItem(id: "mail.more", placement: .primaryAction) { TriageControls(mailbox: mailbox) }
            .mailToolbarVisible(!isCompact)
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
        .mailToolbarVisible(!isCompact)
    }

    private var replies: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "mail.reply", placement: .primaryAction) { replyButton(.reply, title: "Reply", symbol: "arrowshape.turn.up.left") }
                .mailToolbarVisible(!isCompact)
            ToolbarItem(id: "mail.replyAll", placement: .primaryAction) { replyButton(.replyAll, title: "Reply All", symbol: "arrowshape.turn.up.left.2") }
                .mailToolbarVisible(!isCompact)
            ToolbarItem(id: "mail.forward", placement: .primaryAction) { replyButton(.forward, title: "Forward", symbol: "arrowshape.turn.up.right") }
                .mailToolbarVisible(!isCompact)
            ToolbarItem(id: "mail.compactReplies", placement: .primaryAction) {
                Menu { replyActions.labelStyle(.titleAndIcon) } label: {
                    Label("Reply or Forward", systemImage: "arrowshape.turn.up.left")
                }
                .menuIndicator(.visible).help("Reply or Forward")
                .accessibilityLabel("Reply or Forward").disabled(!mailbox.canReply)
            }
            .mailToolbarVisible(isCompact)
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
        Binding(get: { mailbox.labelEdit != nil }, set: { if !$0 { mailbox.labelEdit = nil } })
    }

    private var isMoving: Binding<Bool> {
        Binding(get: { mailbox.moveTargets != nil }, set: { if !$0 { mailbox.moveTargets = nil } })
    }
}

/// macOS 15 can suppress an item without removing its customization definition.
/// Earlier systems retain the supported conditional-content behavior.
extension CustomizableToolbarContent {
    @ToolbarContentBuilder
    func mailToolbarVisible(_ visible: Bool) -> some CustomizableToolbarContent {
        if #available(macOS 15, *) { hidden(!visible) }
        else if visible { self }
    }
}

/// The toolbar's search field. An AppKit field, so ⌥⌘F can focus it on
/// macOS 14. Return asks Gmail and Escape clears the search.
private struct SearchField: NSViewRepresentable {
    let search: SearchModel
    /// Passed in so a change to either updates the field.
    let text: String
    let focusRequest: Int

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search mail"
        field.setAccessibilityLabel("Search mail")
        field.setAccessibilityHelp("Type to search saved mail. Return searches Gmail; Escape clears the search.")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.textChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.search = search
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(search: search, focusRequest: focusRequest)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var search: SearchModel
        var focusRequest: Int

        init(search: SearchModel, focusRequest: Int) {
            self.search = search
            self.focusRequest = focusRequest
        }

        @objc func textChanged(_ sender: NSSearchField) {
            search.update(sender.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                search.submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                search.cancel()
                return true
            default:
                return false
            }
        }
    }
}
