import SwiftUI

extension FocusedValues {
    /// The compose window in front, for the Format menu, Send and Attach Files.
    @Entry var composeModel: ComposeModel?
}

/// The header fields, message editor and quoted text of one draft.
struct ComposeView: View {
    static let minWidth = Tokens.Layout.composeMinWidth
    static let minHeight = Tokens.Layout.composeMinHeight

    enum Field: Hashable {
        case to, cc, bcc, subject, from, message
    }

    /// What a view passes to the one showing the copy its message moved to.
    struct Handoff {
        let localDraftID: String
        /// Where the cursor was, so typing carries on in the same field.
        let focus: Field?
        let senderChange: ComposeModel.SenderChange?
    }

    @State private var model: ComposeModel
    @State private var composeAssistant: ComposeAssistantModel?
    @State private var showsAssistant = false
    @State private var isFileDropTargeted = false
    @State private var isBodyFileDropTargeted = false
    @State private var availableWidth = Tokens.Layout.composeWidth
    @Environment(AppModel.self) private var app
    @State private var hasPlacedFocus = false
    /// A one-shot focus request consumed by the stable header.
    @State private var requestedFocus: Field?
    /// Where the cursor was last while the message could change.
    @State private var lastFocus: Field?
    @Environment(\.dismiss) private var dismiss
    /// Mirrors `model.isEdited` for the window's close button.
    @Binding private var isEdited: Bool
    /// Where the cursor starts in a copy made by a move.
    private let restoredFocus: Field?
    /// Shows the copy the window's message became in another account.
    private let onMove: (Handoff) -> Void
    /// Asks this view's model before the window closes.
    private let closer: ComposeWindowCloser

    init(localDraftID: String, mailbox: MailboxModel, isEdited: Binding<Bool>, handoff: Handoff? = nil,
         closer: ComposeWindowCloser, onMove: @escaping (Handoff) -> Void) {
        _model = State(initialValue: ComposeModel(localDraftID: localDraftID, mailbox: mailbox, senderChange: handoff?.senderChange))
        _isEdited = isEdited
        restoredFocus = handoff?.focus
        self.closer = closer
        self.onMove = onMove
    }

    var body: some View {
        Group {
            if model.phase == .loading {
                if let error = model.storeError {
                    VStack(spacing: Tokens.Space.s4) {
                        TernEmptyState(title: "Couldn't Open This Draft", systemImage: "exclamationmark.triangle",
                                       message: error, fillsSpace: false)
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Opening message…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                form
            }
        }
        .background(Tokens.Surface.primary)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .navigationTitle(model.title)
        .navigationSubtitle(model.status.flatMap { $0.isError ? nil : $0.text } ?? "")
        .toolbar {
            ComposeToolbar(model: model, showsAssistant: $showsAssistant, availableWidth: availableWidth,
                           onCloseAssistant: closeAssistant)
        }
        .toolbar(removing: availableWidth < Tokens.Compose.labeledToolbarWidth ? .title : nil)
        .alert(model.alert?.title ?? "", isPresented: $model.alert.isPresent()) {
            Button("OK") {}
        } message: {
            Text(model.alert?.message ?? "")
        }
        .onChange(of: model.isEdited, initial: true) { _, edited in isEdited = edited }
        .task {
            closer.model = model
            model.start()
            if composeAssistant == nil {
                composeAssistant = ComposeAssistantModel(compose: model, assistant: app.assistant)
            }
        }
        .onChange(of: app.assistant.composeAccessRevision) { composeAssistant?.refreshAccess() }
        .onChange(of: model.isEditable) { _, isEditable in
            if !isEditable { composeAssistant?.clear(); showsAssistant = false }
        }
        .task(id: model.phase) {
            switch model.phase {
            case .loading, .moving: break
            case .open: await placeFocus()
            case .closed: dismiss()
            case .moved(let localDraftID):
                onMove(Handoff(localDraftID: localDraftID, focus: lastFocus, senderChange: model.copySenderChange))
            }
        }
        .onChange(of: model.isEditingMessage) { _, isEditing in if isEditing { noteFocus(.message) } }
        .onDisappear { composeAssistant?.clear(); model.windowClosed() }
        .focusedSceneValue(\.composeModel, model)
    }

    private var form: some View {
        ComposeVerticalLayout {
            VStack(spacing: 0) {
                ComposeNotices(model: model, availableWidth: availableWidth)
                ComposeHeader(model: model, requestedFocus: $requestedFocus, onFocus: noteFocus)
            }
        } formatting: {
            if model.showsFormatting {
                FormatBar(format: model.format, isEnabled: model.canFormat, editor: model.editor) {
                    model.isEditingLink = true
                }
                .ternTransition(.disclosure)
            }
        } editor: {
            ComposeMessageEditor(model: model, isFileDropTargeted: $isBodyFileDropTargeted)
        } supplements: {
            ComposeSupplements(model: model, assistant: app.assistant,
                               composeAssistant: composeAssistant, showsAssistant: showsAssistant,
                               onCloseAssistant: closeAssistant)
        }
        .ternAnimation(value: model.showsFormatting)
        .ternAnimation(value: showsAssistant, duration: Tokens.Motion.slow)
        .ternAnimation(value: model.droppedFormatting)
        .ternAnimation(value: model.status?.isError == true)
        .ternAnimation(value: model.progressText != nil)
        .ternAnimation(value: availableWidth < Tokens.Compose.labeledToolbarWidth && model.status != nil)
        // The AI bar consumes its own drops as context; the rest of the form attaches to mail.
        .composeFileDrop(isEnabled: model.isEditable, isTargeted: $isFileDropTargeted) { files in
            model.attach(files.map(Attachable.dropped))
        }
        .overlay {
            if isFileDropTargeted || isBodyFileDropTargeted {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .fill(Color.accentColor.opacity(Tokens.Opacity.wash))
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.md)
                            .strokeBorder(Color.accentColor, lineWidth: Tokens.Border.focus)
                    }
                    .overlay {
                        Label("Attach to email", systemImage: "paperclip")
                            .font(.headline)
                            .padding(Tokens.Space.s4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    }
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $model.isChoosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls.map(Attachable.file)) }
        }
    }

    private func closeAssistant() {
        composeAssistant?.stop()
        showsAssistant = false
        model.editor?.resumeEditing()
    }

    private func noteFocus(_ field: Field) {
        if model.isEditable { lastFocus = field }
    }

    /// A reply starts in the message; anything without recipients starts in To.
    /// A copy made by a move starts where the cursor was, so the next Tab
    /// goes where it would have gone without the move.
    private func placeFocus() async {
        guard !hasPlacedFocus, let draft = model.draft else { return }
        hasPlacedFocus = true
        // Let the fields and editor join the window first.
        await Task.yield()
        if let restoredFocus {
            requestedFocus = restoredFocus
        } else if draft.to.isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty {
            requestedFocus = .to
        } else if draft.subject.isEmpty {
            requestedFocus = .subject
        } else {
            model.editor?.focus()
        }
    }


}
