import MailStore
import MessageContent
import SwiftUI

extension FocusedValues {
    /// The compose window in front, for the Format menu, Send and Attach Files.
    @Entry var composeModel: ComposeModel?
}

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

/// Steps a new compose window down and right while it would open exactly on
/// top of another one.
private struct ComposeWindowCascade: NSViewRepresentable {
    func makeNSView(context: Context) -> CascadeView { CascadeView() }

    func updateNSView(_ nsView: CascadeView, context: Context) {}

    final class CascadeView: NSView {
        /// Compose windows already placed, which a new one steps away from.
        private static let placed = NSHashTable<NSWindow>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !Self.placed.contains(window) else { return }
            let others = Self.placed.allObjects.filter(\.isVisible)
            Self.placed.add(window)
            // A window that opens as a tab takes its group's frame, so it has nowhere to step.
            let opensAsTab = switch NSWindow.userTabbingPreference {
            case .always: true
            case .inFullScreen: others.contains { $0.styleMask.contains(.fullScreen) }
            default: false
            }
            guard !opensAsTab, !window.styleMask.contains(.fullScreen) else { return }
            func covers(_ other: NSWindow) -> Bool {
                abs(other.frame.minX - window.frame.minX) < 1 && abs(other.frame.maxY - window.frame.maxY) < 1
            }
            var next = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            // One step more than there are other windows is enough to clear them all.
            for _ in 0...others.count where others.contains(where: covers) {
                next = window.cascadeTopLeft(from: next)
            }
        }
    }
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
    @State private var senderAvatars = SenderAvatarModels()
    @Environment(AppModel.self) private var app
    @Environment(\.addressAvatarContext) private var avatarContext
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = DomainLogoPreferences.defaultEnabled
    @State private var showsQuote = false
    @State private var editsQuote = false
    @State private var editsSignature = false
    @State private var hasPlacedFocus = false
    @FocusState private var focus: Field?
    /// The recipient field to move the cursor to. Token fields are AppKit
    /// views, which `focus` can't reach.
    @State private var recipientFocus: Field?
    @State private var focusedRecipient: Field?
    /// Where the cursor was last while the message could change.
    @State private var lastFocus: Field?
    /// Moves the cursor to the end of Subject, which selects all its text when it takes focus.
    @State private var subjectSelection: TextSelection?
    /// Set while the cursor goes back to Subject in a copy made by a move.
    @State private var keepsSubjectText = false
    @State private var highlightsFrom = false
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
        .toolbar { toolbar }
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
        // Runs when the copy of a move the window made by itself opens.
        .task(id: model.phase == .open ? model.senderChange : nil) { await highlightSenderChange() }
        .onChange(of: focus) { _, field in
            if let field { noteFocus(field) }
            if field == .subject, keepsSubjectText {
                keepsSubjectText = false
                subjectSelection = TextSelection(insertionPoint: model.content.subject.endIndex)
            }
        }
        .onChange(of: model.isEditingMessage) { _, isEditing in if isEditing { noteFocus(.message) } }
        .onAppear(perform: configureSenderAvatars)
        .onChange(of: senderAvatarIdentity) { _, _ in configureSenderAvatars() }
        .onDisappear { composeAssistant?.clear(); senderAvatars.stop(); model.windowClosed() }
        .focusedSceneValue(\.composeModel, model)
        .sheet(isPresented: $editsQuote, onDismiss: { model.isEditingSupplement = false }) {
            ComposeQuoteEditor(text: model.draft?.quotedPlainText ?? "") { await model.replaceQuote(with: $0) }
        }
        .sheet(isPresented: $editsSignature, onDismiss: { model.isEditingSupplement = false }) {
            ComposeSignatureEditor(html: model.content.signatureHTML) { model.replaceSignature(with: $0) }
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            if model.droppedFormatting {
                Banner(
                    systemImage: "exclamationmark.triangle",
                    text: "Editing this draft removes tables, fonts and other formatting. Only bold, italic, underline, links and lists are kept."
                ) {
                    model.droppedFormatting = false
                }
                .ternTransition(.disclosure)
            }
            if let status = model.status, status.isError {
                Banner(systemImage: "exclamationmark.circle", text: status.text, isError: true)
                    .ternTransition(.disclosure)
            }
            if let progress = model.progressText {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
                .background(Tokens.Surface.muted)
                .accessibilityElement(children: .combine)
                .ternTransition(.disclosure)
            } else if availableWidth < Tokens.Compose.labeledToolbarWidth,
                      let status = model.status, !status.isError {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Compose.gutter)
                    .padding(.vertical, Tokens.Space.s1_5)
                    .background(Tokens.Surface.muted)
                    .ternTransition(.disclosure)
            }
            header
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.showsFormatting {
                formattingBar
                    .ternTransition(.disclosure)
            }
            RichTextEditor(
                document: $model.content.body,
                format: $model.format,
                isEditable: model.isEditable,
                font: model.content.composeFont,
                inlineImages: model.inlineImageData,
                onDropFiles: { model.attach($0.map(Attachable.dropped)) },
                onFileDropTargetChange: { isBodyFileDropTargeted = $0 }
            ) { model.editor = $0 } onAttach: { model.attach($0, inlineImages: true) } onFocusChange: { model.isEditingMessage = $0 }
            .overlay(alignment: .topLeading) {
                if model.content.body.plainText().isEmpty {
                    Text("Write your message…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Tokens.Compose.gutter + Tokens.Border.hairline)
                        .padding(.top, Tokens.Space.s3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Keep room to write when recipients, files and quoted text are visible.
            // The native window minimum grows with the other controls' intrinsic sizes.
            .frame(minHeight: Tokens.Layout.editorMinHeight)
            // Cmd-K must also work while the formatting bar is hidden. The
            // popover points at the selection, where the link goes.
            .popover(isPresented: $model.isEditingLink, attachmentAnchor: linkAnchor, arrowEdge: .bottom) {
                LinkEditor(existingURL: model.format.linkURL, width: Tokens.Layout.linkEditorWidth) { url in
                    model.editor?.setLink(url)
                }
            }
            if showsAssistant, let composeAssistant {
                ComposeAssistantView(model: composeAssistant, assistant: app.assistant) {
                    closeAssistant()
                }
                .frame(maxWidth: Tokens.Compose.assistantMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(Tokens.Space.s3)
                .ternTransition(.disclosure)
            }
            if showsAttachments {
                AttachmentStrip(
                    attachments: model.attachments.filter { $0.contentID == nil },
                    failed: model.failedAttachments,
                    isEditable: model.isEditable,
                    fileURL: { [model] in await model.attachmentFileURL($0) },
                    retry: { model.retry($0) },
                    dismissFailure: { model.dismissFailure($0) }
                ) {
                    model.removeAttachment($0)
                }
                .ternTransition(.disclosure)
            }
            if model.content.signatureAboveQuote { signature }
            if let quote = model.draft?.quotedPlainText, !quote.isEmpty {
                quotedText(quote)
            }
            if !model.content.signatureAboveQuote { signature }
        }
        .ternAnimation(value: model.showsFormatting)
        .ternAnimation(value: showsAssistant, duration: Tokens.Motion.slow)
        .ternAnimation(value: showsAttachments)
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

    private var showsAttachments: Bool {
        model.attachments.contains(where: { $0.contentID == nil }) || !model.failedAttachments.isEmpty
    }

    private var signature: some View {
        ComposeSignatureView(model: model) {
            model.isEditingSupplement = true
            editsSignature = true
        }
    }

    // MARK: Header

    private var senderAvatarIdentity: String {
        avatarContext.identity + "|\(showsLogos)|" + model.senderChoices.map(\.id).sorted().joined(separator: "|")
    }

    private func configureSenderAvatars() {
        senderAvatars.configure(senders: model.senderChoices, context: avatarContext, showsLogos: showsLogos)
    }

    private var header: some View {
        VStack(spacing: 0) {
            fieldRow("To:", field: .to) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    recipientField("To", addresses: $model.content.to, field: .to)
                    if !model.showsCc {
                        Button { reveal(.cc) } label: {
                            Text("Cc")
                                .font(.caption.weight(.medium))
                                .frame(minWidth: Tokens.Space.s6, minHeight: Tokens.Space.s6)
                                .contentShape(Rectangle())
                        }
                        .help("Add Cc recipients")
                        .accessibilityLabel("Add Cc Recipients")
                    }
                    if !model.showsBcc {
                        Button { reveal(.bcc) } label: {
                            Text("Bcc")
                                .font(.caption.weight(.medium))
                                .frame(minWidth: Tokens.Space.s6, minHeight: Tokens.Space.s6)
                                .contentShape(Rectangle())
                        }
                        .help("Add Bcc recipients")
                        .accessibilityLabel("Add Bcc Recipients")
                    }
                }
                .buttonStyle(.borderless)
            }
            if model.showsCc {
                VStack(spacing: 0) {
                    rowDivider
                    fieldRow("Cc:", field: .cc) {
                        recipientField("Cc", addresses: $model.content.cc, field: .cc)
                    }
                }
                .ternTransition(.disclosure)
            }
            if model.showsBcc {
                VStack(spacing: 0) {
                    rowDivider
                    fieldRow("Bcc:", field: .bcc) {
                        recipientField("Bcc", addresses: $model.content.bcc, field: .bcc)
                    }
                }
                .ternTransition(.disclosure)
            }
            rowDivider
            fieldRow("Subject:", field: .subject) {
                TextField("", text: $model.content.subject, selection: $subjectSelection)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .labelsHidden()
                    .accessibilityLabel("Subject")
                    .focused($focus, equals: .subject)
            }
            if model.showsFrom {
                rowDivider
                fromField
                if let change = model.senderChange {
                    senderChangeNote(change)
                        .ternTransition(.disclosure)
                }
            }
        }
        .disabled(!model.isEditable)
        .padding(.horizontal, Tokens.Compose.gutter - Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s1)
        .background(Tokens.Surface.primary)
        .ternAnimation(value: focus)
        .ternAnimation(value: focusedRecipient)
        .ternAnimation(value: model.showsCc)
        .ternAnimation(value: model.showsBcc)
        .ternAnimation(value: model.senderChange != nil)
    }

    /// Hairlines follow the editable values, leaving the labels quiet.
    private var rowDivider: some View {
        Divider()
            .padding(.leading, Tokens.Space.s2 + Tokens.Layout.composeLabelWidth + Tokens.Space.s2)
            .padding(.trailing, Tokens.Space.s2)
    }

    /// Rows have no border. Focus outlines the whole row, label included.
    private func focusRing(_ isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus)
            // Keeps the ring off the dividers above and below.
            .padding(.vertical, Tokens.Space.s0_5)
            .allowsHitTesting(false)
    }

    /// Replies keep their account while allowing any of its verified From addresses.
    private var fromField: some View {
        Menu {
            ForEach(model.accountChoices, id: \.id) { account in
                let choices = model.senderChoices.filter { $0.account.id == account.id }
                if !choices.isEmpty {
                    Section(account.displayName ?? account.email) {
                        ForEach(choices) { sender in
                            Button { model.selectSender(sender) } label: {
                                HStack {
                                    SenderAccountLabel(account: account, address: sender.label, avatarModel: senderAvatars.models[sender.id])
                                    if sender.id == model.selectedSender?.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                fieldLabel("From:")
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    if let sender = model.selectedSender {
                        SenderAccountLabel(account: sender.account, address: sender.address, avatarModel: senderAvatars.models[sender.id])
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(model.fromEmail).lineLimit(1).truncationMode(.middle)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, Tokens.Space.s2)
            .padding(.vertical, Tokens.Space.s1_5)
            .frame(maxWidth: .infinity, minHeight: Tokens.Control.iconButton)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .controlSize(.regular)
        .focused($focus, equals: .from)
        .background {
            if highlightsFrom {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .fill(Color.accentColor.opacity(Tokens.Opacity.tint))
                    .padding(.vertical, Tokens.Space.s0_5)
                    .ternTransition(.fade)
            }
        }
        .overlay { focusRing(focus == .from) }
        .ternAnimation(value: highlightsFrom)
        .help(model.canChangeAccount ? "Choose a sending address." : "Choose a sending address from this conversation’s account.")
        .accessibilityLabel("From")
        .accessibilityValue(model.fromEmail)
    }

    /// Says why the window changed the sender, with a way back.
    private func senderChangeNote(_ change: ComposeModel.SenderChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Text(change.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.canUndoSenderChange {
                Button("Undo") { model.undoSenderChange() }
                    .controlSize(.small)
                    .help("Send from \(change.previousAccountName) instead")
            }
        }
        // Lines up with the From value above.
        .padding(.leading, Tokens.Space.s2 + Tokens.Layout.composeLabelWidth + Tokens.Space.s2)
        .padding(.trailing, Tokens.Space.s2)
        .padding(.bottom, Tokens.Space.s1_5)
    }

    private func fieldRow<Content: View>(
        _ label: String, field: Field, @ViewBuilder content: () -> Content
    ) -> some View {
        let isFocused = field == .subject ? focus == field : focusedRecipient == field
        return HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            fieldLabel(label)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s1_5)
        .frame(minHeight: Tokens.Control.iconButton)
        .background {
            // Only the background handles blank space. Native editors keep their
            // own mouse events for cursor placement, token selection and dragging.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusField(field) }
                .accessibilityHidden(true)
        }
        .overlay { focusRing(isFocused) }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: Tokens.Layout.composeLabelWidth, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func focusField(_ field: Field) {
        guard model.isEditable else { return }
        switch field {
        case .subject, .from:
            recipientFocus = nil
            focus = field
        case .to, .cc, .bcc:
            focus = nil
            recipientFocus = field
        case .message:
            focus = nil
            recipientFocus = nil
            model.editor?.focus()
        }
    }

    private func noteFocus(_ field: Field) {
        if model.isEditable { lastFocus = field }
    }

    private func recipientField(_ label: String, addresses: Binding<[EmailAddress]>, field: Field) -> some View {
        // Never ask the token field itself; see `RecipientField.firstBaseline`.
        let baseline = RecipientField.firstBaseline
        return RecipientField(
            label: label,
            addresses: addresses,
            requestsFocus: $recipientFocus.equals(field),
            isEditable: model.isEditable,
            accountID: model.draft?.accountID,
            avatarContext: avatarContext,
            onFocusChange: { isFocused in
                if isFocused {
                    focusedRecipient = field
                    noteFocus(field)
                } else if focusedRecipient == field {
                    focusedRecipient = nil
                }
            },
            directorySuggestions: { [model] text in await model.directorySuggestions(for: text) },
            groupSuggestions: { [model] text in await model.groupSuggestions(for: text) },
            expandGroup: { [model] group in await model.expandGroup(group) },
            groupExpansionChanged: model.groupExpansionChanged,
            blockSuggestion: { [model] address in await model.blockSuggestion(address) }
        ) { [model] text in
            await model.suggestions(for: text)
        }
        .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }

    /// Where the link popover points: the text it links, or the whole editor
    /// when the selection isn't known.
    private var linkAnchor: PopoverAttachmentAnchor {
        model.linkAnchor.map { .rect(.rect($0)) } ?? .rect(.bounds)
    }

    private func reveal(_ field: Field) {
        switch field {
        case .cc: model.showsCc = true
        case .bcc: model.showsBcc = true
        case .to, .subject, .from, .message: break
        }
        focusField(field)
    }

    // MARK: Quoted text

    private func quotedText(_ quote: String) -> some View {
        let noun = model.draft?.kind == .forward ? "Forwarded Message" : "Quoted Text"
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                showsQuote.toggle()
            } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: Tokens.Space.s3)
                        .rotationEffect(.degrees(showsQuote ? 90 : 0))
                    Image(systemName: "text.quote")
                        .frame(width: Tokens.Control.icon)
                    Text(noun)
                        .font(.caption.weight(.medium))
                    Spacer(minLength: Tokens.Space.s2)
                    Text("Included").font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Compose.gutter)
                .padding(.vertical, Tokens.Space.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Included unchanged below your message, even when hidden.")
            .accessibilityLabel(showsQuote ? "Hide \(noun)" : "Show \(noun)")
            .accessibilityValue(showsQuote ? "Expanded" : "Collapsed")
            if showsQuote {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Tokens.Space.s2) {
                        Button("Edit Quotation") {
                            model.isEditingSupplement = true
                            editsQuote = true
                        }
                        .accessibilityIdentifier("compose-edit-quote")
                        Spacer()
                    }
                    .controlSize(.small)
                    .disabled(!model.isEditable)
                    .padding(.horizontal, Tokens.Compose.gutter)
                    .padding(.bottom, Tokens.Space.s2)
                    ScrollView {
                        Text(quote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Compose.gutter)
                            .padding(.bottom, Tokens.Space.s2)
                    }
                    .frame(minHeight: Tokens.Space.s16, maxHeight: Tokens.Layout.quoteMaxHeight)
                }
                .ternTransition(.disclosure)
            }
        }
        .background(Tokens.Surface.muted)
        .overlay(alignment: .top) { Divider() }
        .ternAnimation(value: showsQuote, duration: Tokens.Motion.slow)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // On the leading side, far from Send.
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.discard() }
            } label: {
                Label("Discard Draft", systemImage: "trash")
            }
            .help("Discard Draft")
            .disabled(!model.isEditable)
        }
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                if showsAssistant { closeAssistant() }
                else { showsAssistant = true }
            } label: {
                toolbarLabel("Ask AI", systemImage: "sparkles")
                    .foregroundStyle(showsAssistant ? Color.accentColor : .primary)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .help(showsAssistant ? "Close compose assistant (⇧⌘J)" : "Ask the assistant to help write (⇧⌘J)")
            .accessibilityLabel("Compose Assistant")
            .accessibilityValue(showsAssistant ? "Open" : "Closed")
            .disabled(!model.isEditable)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showsFormatting.toggle()
            } label: {
                Label("Formatting", systemImage: "textformat")
                    .foregroundStyle(model.showsFormatting ? Color.accentColor : .primary)
            }
            .labelStyle(.iconOnly)
            .help(model.showsFormatting ? "Hide Formatting" : "Show Formatting")
            .accessibilityLabel("Formatting")
            .accessibilityValue(model.showsFormatting ? "Expanded" : "Collapsed")
            .disabled(!model.isEditable)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isChoosingFiles = true
            } label: {
                Label("Attach Files", systemImage: "paperclip")
            }
            .help("Attach Files")
            .disabled(!model.isEditable)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("Request Read Receipt", isOn: $model.content.requestsReadReceipt)
                Text("Receipts depend on the recipient's email app and settings.")
                if !model.templates.isEmpty || model.canSendAndArchive { Divider() }
                if !model.templates.isEmpty {
                    Menu("Insert Template", systemImage: "doc.text") {
                        ForEach(model.templates) { template in
                            Button(template.name) { model.insertTemplate(template) }
                        }
                    }
                }
                if model.canSendAndArchive {
                    if !model.templates.isEmpty { Divider() }
                    Button("Send and Archive", systemImage: "archivebox") { Task { await model.send(archive: true) } }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .foregroundStyle(model.content.requestsReadReceipt ? Color.accentColor : .primary)
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .help(model.content.requestsReadReceipt ? "Read receipt requested. More compose actions" : "More compose actions")
            .accessibilityLabel("More Compose Actions")
            .accessibilityValue(model.content.requestsReadReceipt ? "Read receipt requested" : "")
            .disabled(!model.isEditable)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.send() }
            } label: {
                Label("Send", systemImage: "paperplane")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .help("Send (⇧⌘D)")
            .accessibilityLabel("Send")
            .disabled(!model.isEditable)
        }
    }

    private var formattingBar: some View {
        FormatBar(format: model.format, isEnabled: model.canFormat, editor: model.editor) {
            model.isEditingLink = true
        }
    }

    // MARK: Private

    private func closeAssistant() {
        composeAssistant?.stop()
        showsAssistant = false
        model.editor?.resumeEditing()
    }

    @ViewBuilder private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        if availableWidth >= Tokens.Compose.labeledToolbarWidth {
            Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
        } else {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }
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
            // Typing carries on after the subject instead of replacing it.
            keepsSubjectText = restoredFocus == .subject
            reveal(restoredFocus)
        } else if draft.to.isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty {
            recipientFocus = .to
        } else if draft.subject.isEmpty {
            focus = .subject
        } else {
            model.editor?.focus()
        }
    }

    /// Lights up the From row for a moment and reads the note aloud.
    private func highlightSenderChange() async {
        guard let change = model.senderChange, model.phase == .open else {
            highlightsFrom = false
            return
        }
        AccessibilityNotification.Announcement(change.note).post()
        highlightsFrom = true
        try? await Task.sleep(for: Tokens.Toast.info)
        highlightsFrom = false
    }
}

/// Sets the hosting window's edited state, which the close button shows as a dot.
private struct WindowEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.isEdited = isEdited
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.isEdited = isEdited
    }

    final class MarkerView: NSView {
        var isEdited = false {
            didSet { window?.isDocumentEdited = isEdited }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isDocumentEdited = isEdited
        }
    }
}

/// Decides whether the compose window may close. A draft that closing
/// would store goes first, and the window closes once that worked. A store
/// that fails keeps the window open with the error and the draft.
@MainActor
final class ComposeWindowCloser {
    /// The model of the draft the window shows, which changes when the message moves to another account.
    weak var model: ComposeModel?

    func shouldClose() -> Bool {
        guard let model, !model.closesAtOnce else { return true }
        Task { await model.requestClose() }
        return false
    }
}

/// A note across the top of the window.
private struct Banner: View {
    let systemImage: String
    let text: String
    var isError = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Image(systemName: systemImage)
                .foregroundStyle(isError ? Tokens.Status.error : Tokens.Status.warning)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button("OK", action: dismiss)
            }
        }
        .font(.callout)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.muted)
        .accessibilityElement(children: .combine)
    }
}

/// Asks for a link's address.
struct LinkEditor: View {
    let existingURL: URL?
    let width: CGFloat
    let apply: (URL?) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var hasLink: Bool { existingURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(title: hasLink ? "Edit Link" : "Add Link", systemImage: "link")
            TextField("Web or email address", text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Link address")
                .focused($isFocused)
                .onSubmit(add)
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s5)
            PopupFooter {
                if hasLink {
                    Button("Remove Link") {
                        apply(nil)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(hasLink ? "Update Link" : "Add Link", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ComposeModel.linkURL(from: text) == nil)
            }
        }
        .frame(width: width)
        .onAppear {
            text = existingURL?.absoluteString ?? ""
            isFocused = true
        }
    }

    private func add() {
        guard let url = ComposeModel.linkURL(from: text) else { return }
        apply(url)
        dismiss()
    }
}
