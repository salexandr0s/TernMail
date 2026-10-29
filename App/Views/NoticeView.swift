import SwiftUI

/// The toast at the bottom of the window. It stays while the pointer is over it.
struct NoticeView: View {
    let notice: MailboxModel.Notice
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(notice.isError ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Tokens.Space.s0_5)
            Spacer(minLength: Tokens.Space.s2)
            if notice.undo != nil {
                Button("Undo", action: onUndo)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: Tokens.Toast.width)
        .ternSurface()
        .shadow(color: Tokens.Shadow.mdColor, radius: Tokens.Shadow.mdRadius, y: Tokens.Shadow.mdY)
        .onHover { isHovering = $0 }
        .task(id: isHovering) {
            guard !isHovering else { return }
            try? await Task.sleep(for: notice.duration ?? (notice.isError ? Tokens.Toast.error : Tokens.Toast.info))
            if !Task.isCancelled { onDismiss() }
        }
        .onAppear {
            AccessibilityNotification.Announcement(notice.message).post()
        }
    }
}
