import AppKit
import SwiftUI

/// The drop destination spans the row, including the space beyond its title.
private struct SidebarRowFeedback: ViewModifier {
    let mailbox: MailboxModel
    let box: MailboxID
    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var copiesLabel = false

    func body(content: Content) -> some View {
        Group {
            if case .moveToLabel = mailbox.dropAction(for: box) {
                content.help("Drag to move mail here. Hold Option to add this label and keep mail in its current folder.")
            } else {
                content
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: ConversationDragItem.self, isEnabled: mailbox.acceptsDrop(on: box)) { items, _ in
                mailbox.drop(items, on: box, copy: copiesLabel)
                isTargeted = false
            }
            .dropConfiguration { session in DropConfiguration(operation: operation(for: session)) }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active:
                    let operation = operation(for: session)
                    isTargeted = operation != .forbidden && operation != .cancel
                    copiesLabel = operation == .copy
                case .ended(let operation):
                    copiesLabel = operation == .copy
                    isTargeted = false
                case .exiting, .dataTransferCompleted:
                    isTargeted = false
                @unknown default:
                    isTargeted = false
                }
            }
            .accessibilityIdentifier(box.sidebarAccessibilityIdentifier)
            .listRowInsets(.horizontal, Tokens.Space.s2)
            .onHover { isHovered = $0 }
            .listRowBackground(highlight.map { color in
                RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(color)
                    .padding(.horizontal, Tokens.Space.s2 + Tokens.Space.s0_5)
            })
            .ternAnimation(value: isHovered || isTargeted)
    }

    private func operation(for session: DropSession) -> DropOperation {
        let rows = session.localSession?.draggedItemIDs(for: MailListRowID.self)
        guard mailbox.acceptsDrop(on: box, rows: rows.map(Set.init)) else { return .forbidden }
        switch mailbox.dropAction(for: box, copy: NSEvent.modifierFlags.contains(.option)) {
        case .addLabel: return .copy
        case .none: return .forbidden
        default: return .move
        }
    }

    private var highlight: Color? {
        if isTargeted { return Color.accentColor.opacity(Tokens.Opacity.tint) }
        guard mailbox.sidebarSelection != box else { return nil }
        return isHovered ? Color.primary.opacity(Tokens.Opacity.hover) : nil
    }
}

extension MailboxID {
    var sidebarAccessibilityIdentifier: String {
        switch self {
        case .account(let account, let label): "sidebar.mailbox.\(account).\(label)"
        case .combined(let label): "sidebar.mailbox.combined.\(label)"
        case .scoped(let label, let accounts): "sidebar.mailbox.\(accounts.sorted().joined(separator: ",")).\(label)"
        }
    }
}

extension View {
    func conversationDropTarget(_ box: MailboxID, mailbox: MailboxModel) -> some View {
        modifier(SidebarRowFeedback(mailbox: mailbox, box: box))
    }
}
