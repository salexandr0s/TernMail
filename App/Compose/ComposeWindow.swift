import SwiftUI

/// A compose window's content: waits for the mailbox, then edits one draft.
struct ComposeWindow: View {
    static let sceneID = "compose"

    /// Changes when the message moves to another account, which makes a copy.
    @Binding var localDraftID: String?
    /// What the view of the moved message passes to the copy's view.
    @State private var handoff: ComposeView.Handoff?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The draft differs from its last save, so the close button shows a dot.
    @State private var isEdited = false
    /// Asks the draft's model before the window closes.
    @State private var closer = ComposeWindowCloser()

    var body: some View {
        Group {
            if let id = localDraftID, let mailbox = app.mailbox {
                ComposeView(localDraftID: id, mailbox: mailbox, isEdited: $isEdited,
                            handoff: handoff?.localDraftID == id ? handoff : nil, closer: closer) {
                    handoff = $0
                    localDraftID = $0.localDraftID
                }
                    // Each draft, and a new sign-in's mailbox, needs its own model.
                    .id(id)
                    .id(ObjectIdentifier(mailbox))
            } else {
                ProgressView("Opening message…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ComposeView.minWidth, minHeight: ComposeView.minHeight)
        .background { WindowEditedMarker(isEdited: isEdited) }
        .background { WindowCloseGuard { [closer] _ in closer.shouldClose() } }
        .background { ComposeWindowCascade() }
        .task(id: app.phase) {
            if localDraftID == nil || app.phase == .signedOut { dismiss() }
        }
    }
}
