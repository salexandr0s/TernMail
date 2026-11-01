import SwiftUI

/// Hover and drop feedback use the whole sidebar row. Selection remains native.
private struct SidebarRowFeedback: ViewModifier {
    let mailbox: MailboxModel
    let box: MailboxID
    @State private var isHovered = false
    @State private var isTargeted = false
    private var isDropTarget: Bool { isTargeted && mailbox.acceptsDrop(on: box) }

    func body(content: Content) -> some View {
        Group {
            if mailbox.acceptsDrop(on: box) {
                content
                    .dropDestination(for: ConversationDragItem.self) { items, _ in
                        mailbox.drop(items, on: box)
                    } isTargeted: { isTargeted = $0 }
            } else {
                content
            }
        }
        .onHover { isHovered = $0 }
        .listRowBackground(highlight.map { color in
            RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(color)
                .padding(.horizontal, Tokens.Space.s2 + Tokens.Space.s0_5)
        })
        .ternAnimation(value: isHovered || isDropTarget)
    }

    private var highlight: Color? {
        guard mailbox.sidebarSelection != box else { return nil }
        if isDropTarget { return Color.accentColor.opacity(Tokens.Opacity.tint) }
        return isHovered ? Color.primary.opacity(Tokens.Opacity.hover) : nil
    }
}

extension View {
    func conversationDropTarget(_ box: MailboxID, mailbox: MailboxModel) -> some View {
        modifier(SidebarRowFeedback(mailbox: mailbox, box: box))
    }
}
