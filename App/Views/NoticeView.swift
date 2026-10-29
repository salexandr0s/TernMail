import SwiftUI

/// The toast at the bottom of the window. It stays while the pointer is over it.
struct NoticeView: View {
    let notice: MailboxModel.Notice
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            if notice.isError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(notice.message)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tokens.Space.s2)
            if notice.undo != nil {
                Button("Undo", action: onUndo)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Tokens.Space.s4)
        .frame(width: Tokens.Toast.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(.separator)
        }
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
