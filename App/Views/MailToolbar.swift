import AppKit
import MessageContent
import SwiftUI

/// The main window's toolbar over the conversation: triage actions, then
/// replies, then search, in the order mail apps on the Mac use.
struct MailToolbar: ToolbarContent {
    @Bindable var mailbox: MailboxModel
    let reply: (ReplyKind) -> Void
    var isCompact = false

    var body: some ToolbarContent {
        let ids = mailbox.selectedThreadIDs
        let isRead = mailbox.allRead(ids)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { mailbox.perform(.archive) } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Archive")
            .disabled(!mailbox.canArchive)

            Button { mailbox.perform(.trash) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move to Trash")
            .disabled(!mailbox.canTrash)

            Button { mailbox.toggleRead() } label: {
                Label(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open")
            }
            .help(isRead ? "Mark as Unread" : "Mark as Read")
            .disabled(ids.isEmpty)

            // The menu commands and the context menu open these popovers too.
            Button { mailbox.showMoveTo() } label: {
                Label("Move to", systemImage: "folder")
            }
            .help("Move to")
            .disabled(ids.isEmpty)
            .popover(isPresented: isMoving, arrowEdge: .bottom) {
                MoveToView(targets: mailbox.moveChoices, onMove: { mailbox.move(to: $0) })
            }

            Button { mailbox.showEditLabels() } label: {
                Label("Edit Labels", systemImage: "tag")
            }
            .help("Edit Labels")
            .disabled(ids.isEmpty)
            .popover(isPresented: isEditingLabels, arrowEdge: .bottom) {
                if let edit = mailbox.labelEdit {
                    EditLabelsView(
                        labels: mailbox.labelChoices,
                        applied: edit.applied,
                        onApply: { mailbox.applyLabels($0) },
                        onCreateLabel: { mailbox.createLabel(named: $0, after: $1) }
                    )
                }
            }

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
            // Without it, VoiceOver names the menu after its arrow image.
            .accessibilityLabel("Snooze")
            .help("Snooze")
            .disabled(!mailbox.canSnooze)
        }

        // Liquid Glass draws each run of items as one capsule. Earlier
        // systems space the groups apart on their own.
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if isCompact {
                Menu {
                    replyActions
                        .labelStyle(.titleAndIcon)
                } label: {
                    Label("Reply or Forward", systemImage: "arrowshape.turn.up.left")
                }
                .menuIndicator(.visible)
                .help("Reply or Forward")
                .accessibilityLabel("Reply or Forward")
                .disabled(!mailbox.canReply)
            } else {
                replyActions
            }
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            SearchField(
                search: mailbox.search,
                text: mailbox.search.text,
                focusRequest: mailbox.search.fieldFocusRequest
            )
            .frame(
                minWidth: Tokens.Layout.searchMinWidth,
                idealWidth: isCompact ? Tokens.Layout.searchMinWidth : Tokens.Layout.searchWidth,
                maxWidth: isCompact ? Tokens.Layout.searchMinWidth : Tokens.Layout.searchMaxWidth
            )
            .help("Search mail (⌥⌘F). Return searches Gmail.")
        }
    }

    @ViewBuilder
    private var replyActions: some View {
        Button { reply(.reply) } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        .help("Reply")
        .disabled(!mailbox.canReply)

        Button { reply(.replyAll) } label: {
            Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
        }
        .help("Reply All")
        .disabled(!mailbox.canReply)

        Button { reply(.forward) } label: {
            Label("Forward", systemImage: "arrowshape.turn.up.right")
        }
        .help("Forward")
        .disabled(!mailbox.canReply)
    }

    private var isEditingLabels: Binding<Bool> {
        Binding(get: { mailbox.labelEdit != nil }, set: { if !$0 { mailbox.labelEdit = nil } })
    }

    private var isMoving: Binding<Bool> {
        Binding(get: { mailbox.moveTargets != nil }, set: { if !$0 { mailbox.moveTargets = nil } })
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
