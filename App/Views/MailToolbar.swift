import MessageContent
import SwiftUI

/// The main window's toolbar over the conversation: triage actions, then
/// replies, in the order mail apps on the Mac use. The window's search
/// field follows them (`WorkspaceSearch`). Fixed spacers split the actions
/// into groups, since adjacent items otherwise share one glass capsule.
struct MailToolbar: CustomizableToolbarContent {
    let mailbox: MailboxModel
    let reply: (ReplyKind, SelectedMailQuote?) -> Void
    var isCompact = false
    /// Hidden while the window shows Calendar or the attachment library. Each
    /// group reads it here because an inner `hidden(false)` would win over one
    /// applied to the whole toolbar.
    var isVisible = true

    private var showsStandard: Bool { isVisible && !isCompact }
    private var showsCompact: Bool { isVisible && isCompact }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "mail.archive", placement: .primaryAction) {
            MailToolbarActions.Archive(mailbox: mailbox)
        }
        .mailToolbarVisible(isVisible)
        ToolbarItem(id: "mail.trash", placement: .primaryAction) {
            MailToolbarActions.Trash(mailbox: mailbox)
        }
        .mailToolbarVisible(isVisible)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        standardTriage
        ToolbarItem(id: "mail.compactActions", placement: .primaryAction) {
            MailToolbarActions.CompactActions(mailbox: mailbox)
        }
        .mailToolbarVisible(showsCompact)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        replies
    }

    /// More closes this group because compact windows fold the whole group
    /// into one menu. Both layouts then use the same spaces, which matters
    /// since `ToolbarSpacer` ignores `hidden(_:)`.
    private var standardTriage: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "mail.read", placement: .primaryAction) { MailToolbarActions.Read(mailbox: mailbox) }
            ToolbarItem(id: "mail.move", placement: .primaryAction) {
                MailToolbarActions.Move(mailbox: mailbox)
            }
            ToolbarItem(id: "mail.labels", placement: .primaryAction) {
                MailToolbarActions.Labels(mailbox: mailbox)
            }
            ToolbarItem(id: "mail.snooze", placement: .primaryAction) { MailToolbarActions.Snooze(mailbox: mailbox) }
            ToolbarItem(id: "mail.more", placement: .primaryAction) { TriageControls(mailbox: mailbox) }
        }
        .mailToolbarVisible(showsStandard)
    }

    private var replies: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "mail.reply", placement: .primaryAction) {
                MailToolbarActions.Reply(mailbox: mailbox, kind: .reply, title: "Reply", symbol: "arrowshape.turn.up.left", reply: reply)
            }
            .mailToolbarVisible(showsStandard)
            ToolbarItem(id: "mail.replyAll", placement: .primaryAction) {
                MailToolbarActions.Reply(mailbox: mailbox, kind: .replyAll, title: "Reply All", symbol: "arrowshape.turn.up.left.2", reply: reply)
            }
            .mailToolbarVisible(showsStandard)
            ToolbarItem(id: "mail.forward", placement: .primaryAction) {
                MailToolbarActions.Reply(mailbox: mailbox, kind: .forward, title: "Forward", symbol: "arrowshape.turn.up.right", reply: reply)
            }
            .mailToolbarVisible(showsStandard)
            ToolbarItem(id: "mail.compactReplies", placement: .primaryAction) {
                MailToolbarActions.CompactReplies(mailbox: mailbox, reply: reply)
            }
            .mailToolbarVisible(showsCompact)
        }
    }
}

/// Suppresses an item without removing its customization definition.
/// `ToolbarSpacer` ignores it, so spacers stay in every section. Spacers
/// can't go in an `if` either: AppKit repeats each insert in the other
/// toolbars that share the identifier, and a repeated Search item throws.
extension CustomizableToolbarContent {
    func mailToolbarVisible(_ visible: Bool) -> some CustomizableToolbarContent {
        hidden(!visible)
    }
}
