import SwiftUI

/// The toast at the bottom of the window. Hovering or focusing an action keeps it open.
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
        .onHover { isHovering = $0 }
        .task(id: isInteracting) {
            guard !isInteracting else { return }
            try? await Task.sleep(for: notice.duration ?? (notice.isError ? Tokens.Toast.error : Tokens.Toast.info))
            if !Task.isCancelled { onDismiss() }
        }
        .onAppear {
            AccessibilityNotification.Announcement(notice.message).post()
        }
    }
}
