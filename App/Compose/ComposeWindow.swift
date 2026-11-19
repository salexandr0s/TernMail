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
    /// Keeps what is typed before the draft's fields can take it. It outlives
    /// a move to another account, so the copy gets what was typed meanwhile.
    @State private var typeAhead = ComposeTypeAhead()

    var body: some View {
        Group {
            if let id = localDraftID, let mailbox = app.mailbox {
                ComposeView(localDraftID: id, mailbox: mailbox, isEdited: $isEdited,
                            handoff: handoff?.localDraftID == id ? handoff : nil, closer: closer,
                            typeAhead: typeAhead) {
                    handoff = $0
                    localDraftID = $0.localDraftID
                }
                    // Each draft, and a new sign-in's mailbox, needs its own model.
                    .id(id)
                    .id(ObjectIdentifier(mailbox))
            } else {
                ProgressView("Opening message…")
                    .ternDelayedLoading()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ComposeView.minWidth, minHeight: ComposeView.minHeight)
        .background { ComposeTypeAheadAnchor(typeAhead: typeAhead, localDraftID: localDraftID) }
        .background { WindowEditedMarker(isEdited: isEdited) }
        .background { WindowCloseGuard { [closer] _ in closer.shouldClose() } }
        .background { ComposeWindowCascade() }
        .task(id: app.phase) {
            if localDraftID == nil || app.phase == .signedOut { dismiss() }
        }
    }

    /// Opens the window of the draft `makeDraft` returns. What is typed while
    /// the draft is made goes to that window, which it was meant for.
    static func open(with openWindow: OpenWindowAction, makeDraft: @escaping @MainActor () async -> String?) {
        let keys = ComposeTypeAhead.catchKeys()
        Task {
            guard let id = await makeDraft() else {
                keys.drop()
                return
            }
            keys.wait(for: id)
            openWindow(id: sceneID, value: id)
        }
    }

    /// Makes a draft for a window that a mail link, another app, the Dock or
    /// a notification opens. Tern may not have been in front, so keys typed
    /// in any of Tern's windows are kept for the new window until it opens,
    /// with the exceptions `ComposeTypeAhead.catchKeysInAnyWindow()` lists.
    /// `isCurrent` runs once the draft exists. When it fails, or there is no
    /// draft, the kept keys are dropped and this returns nil.
    static func makeDraft(isCurrent: () -> Bool = { true },
                          _ make: @MainActor () async -> String?) async -> String? {
        let keys = ComposeTypeAhead.catchKeysInAnyWindow()
        guard let id = await make(), isCurrent() else {
            keys.drop()
            return nil
        }
        keys.wait(for: id)
        return id
    }
}
