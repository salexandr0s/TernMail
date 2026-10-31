import SwiftUI

/// A sidebar row that takes dragged conversations. It tints while a drag
/// hovers, and stays out of the drop until the mailbox can change the mail.
private struct ConversationDropTarget: ViewModifier {
    let mailbox: MailboxModel
    let box: MailboxID
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if mailbox.acceptsDrop(on: box) {
            content
                .background(Color.accentColor.opacity(isTargeted ? Tokens.Opacity.tint : 0),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .ternAnimation(value: isTargeted)
                .dropDestination(for: ConversationDragItem.self) { items, _ in
                    mailbox.drop(items, on: box)
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

extension View {
    func conversationDropTarget(_ box: MailboxID, mailbox: MailboxModel) -> some View {
        modifier(ConversationDropTarget(mailbox: mailbox, box: box))
    }
}
