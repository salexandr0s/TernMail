import SwiftUI

/// Errors stay available until dismissed. Hovering or focusing an action
/// keeps an informational notice open without changing its action's deadline.
struct NoticeView: View {
    let notice: MailboxModel.Notice
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case undo, dismiss
    }

    private var isInteracting: Bool { isHovering || focusedAction != nil }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(notice.isError ? Tokens.Status.warning : Color.accentColor)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Tokens.Space.s0_5)
            Spacer(minLength: Tokens.Space.s2)
            if notice.undo != nil {
                Button("Undo", action: onUndo)
                    .controlSize(.small)
                    .focused($focusedAction, equals: .undo)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
            }
            .buttonStyle(.borderless)
            .focused($focusedAction, equals: .dismiss)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: Tokens.Toast.width)
        .ternSurface()
        .shadow(color: Tokens.Shadow.mdColor, radius: Tokens.Shadow.mdRadius, y: Tokens.Shadow.mdY)
        .ternOnHover { isHovering = $0 }
        .task(id: isInteracting) {
            guard !isInteracting, !notice.isError else { return }
            try? await Task.sleep(for: notice.duration ?? Tokens.Toast.info)
            if !Task.isCancelled { onDismiss() }
        }
        .onAppear {
            AccessibilityNotification.Announcement(notice.message).post()
        }
    }
}

/// Notices in the window's bottom corner. Mail and the attachment library
/// each draw it, because the library hides the mail view while it shows.
struct MailNoticeOverlay: ViewModifier {
    let mailbox: MailboxModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: Tokens.Space.s2) {
                if let notice = mailbox.sendNotice {
                    NoticeView(notice: notice) {
                        if let undo = notice.undo { self.undo(undo) }
                    } onDismiss: {
                        if mailbox.sendNotice?.id == notice.id { mailbox.sendNotice = nil }
                    }
                    .ternTransition(.toast)
                    .id(notice.id)
                }
                if let notice = mailbox.notice {
                    NoticeView(notice: notice) {
                        if let undo = notice.undo { self.undo(undo) }
                    } onDismiss: {
                        if mailbox.notice?.id == notice.id { mailbox.notice = nil }
                    }
                    .ternTransition(.toast)
                    .id(notice.id)
                }
            }
            .padding(Tokens.Space.s4)
            .ternAnimation(value: mailbox.notice?.id)
            .ternAnimation(value: mailbox.sendNotice?.id)
        }
    }

    private func undo(_ undo: MailboxModel.Notice.Undo) {
        switch undo {
        case .action(let row):
            mailbox.undo(row)
        case .send(let id):
            ComposeWindow.open(with: openWindow) { await mailbox.undoSend(id) ? id : nil }
        case .discard(let id):
            ComposeWindow.open(with: openWindow) { await mailbox.undoDiscard(id) ? id : nil }
        }
    }
}
