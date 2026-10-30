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
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let id = localDraftID, let mailbox = app.mailbox {
                ComposeView(localDraftID: id, mailbox: mailbox) { localDraftID = $0 }
                    // Each draft, and a new sign-in's mailbox, needs its own model.
                    .id(id)
                    .id(ObjectIdentifier(mailbox))
            } else {
                ProgressView("Opening message…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ComposeView.minWidth, minHeight: ComposeView.minHeight)
        .task(id: app.phase) {
            if localDraftID == nil || app.phase == .signedOut { dismiss() }
        }
    }
}

/// The header fields, message editor and quoted text of one draft.
struct ComposeView: View {
    static let minWidth = Tokens.Layout.composeMinWidth
    static let minHeight = Tokens.Layout.composeMinHeight

    private enum Field: Hashable {
        case to, cc, bcc, subject, from
    }

    @State private var model: ComposeModel
    @State private var showsQuote = false
    @State private var showsFormatting = false
    @State private var hasPlacedFocus = false
    @FocusState private var focus: Field?
    /// The recipient field to move the cursor to. Token fields are AppKit
    /// views, which `focus` can't reach.
    @State private var recipientFocus: Field?
    @State private var focusedRecipient: Field?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dismiss) private var dismiss
    /// Shows the copy the window's message became in another account.
    private let onMove: (String) -> Void

    init(localDraftID: String, mailbox: MailboxModel, onMove: @escaping (String) -> Void) {
        _model = State(initialValue: ComposeModel(localDraftID: localDraftID, mailbox: mailbox))
        self.onMove = onMove
    }

    var body: some View {
        Group {
            if model.phase == .loading {
                if let error = model.storeError {
                    VStack(spacing: Tokens.Space.s4) {
                        TernEmptyState(title: "Couldn't open this draft", systemImage: "exclamationmark.triangle",
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
        .navigationTitle(model.title)
        .navigationSubtitle(model.status.flatMap { $0.isError ? nil : $0.text } ?? "")
        .toolbar { toolbar }
        .alert(model.alert ?? "", isPresented: isShowingAlert) {
            Button("OK") {}
        }
        .task { model.start() }
        .task(id: model.phase) {
            switch model.phase {
            case .loading, .moving: break
            case .open: await placeFocus()
            case .closed: dismiss()
            case .moved(let localDraftID): onMove(localDraftID)
            }
        }
        .onDisappear { model.windowClosed() }
        .focusedSceneValue(\.composeModel, model)
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
            }
            if let status = model.status, status.isError {
                Banner(systemImage: "exclamationmark.circle", text: status.text, isError: true)
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
            }
            header
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if showsFormatting {
                formattingBar
                    .transition(.opacity)
            }
            RichTextEditor(
                document: $model.content.body,
                format: $model.format,
                isEditable: model.isEditable
            ) { model.editor = $0 } onAttach: { model.attach($0) } onFocusChange: { model.isEditingMessage = $0 }
            // Keep room to write when recipients, files and quoted text are visible.
            // The native window minimum grows with the other controls' intrinsic sizes.
            .frame(minHeight: Tokens.Space.s16 * 2)
            if !model.attachments.isEmpty {
                AttachmentStrip(attachments: model.attachments, isEditable: model.isEditable) {
                    model.removeAttachment($0)
                }
            }
            if let quote = model.draft?.quotedPlainText, !quote.isEmpty {
                quotedText(quote)
            }
        }
        .ternAnimation(value: showsFormatting)
        // Files dropped outside the message, which handles its own drops.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard model.isEditable, !files.isEmpty else { return false }
            model.attach(files.map(Attachable.file))
            return true
        }
        .fileImporter(isPresented: $model.isChoosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls.map(Attachable.file)) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Tokens.Space.s1) {
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
                    }
                    if !model.showsBcc {
                        Button { reveal(.bcc) } label: {
                            Text("Bcc")
                                .font(.caption.weight(.medium))
                                .frame(minWidth: Tokens.Space.s6, minHeight: Tokens.Space.s6)
                                .contentShape(Rectangle())
                        }
                        .help("Add Bcc recipients")
                    }
                }
                .buttonStyle(.borderless)
            }
            if model.showsCc {
                fieldRow("Cc:", field: .cc) {
                    recipientField("Cc", addresses: $model.content.cc, field: .cc)
                }
            }
            if model.showsBcc {
                fieldRow("Bcc:", field: .bcc) {
                    recipientField("Bcc", addresses: $model.content.bcc, field: .bcc)
                }
            }
            fieldRow("Subject:", field: .subject) {
                TextField("", text: $model.content.subject)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .labelsHidden()
                    .accessibilityLabel("Subject")
                    .focused($focus, equals: .subject)
            }
            if model.showsFrom {
                fromField
            }
        }
        .disabled(!model.isEditable)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.primary)
        .ternAnimation(value: focus)
        .ternAnimation(value: focusedRecipient)
    }

    /// A new message can move to another account. A reply or a Gmail draft
    /// stays in the account of its thread.
    @ViewBuilder private var fromField: some View {
        if model.canChangeAccount {
            Menu {
                Picker("From", selection: Binding(get: { model.draft?.accountID ?? "" }, set: { model.move(to: $0) })) {
                    ForEach(model.accountChoices, id: \.id) { account in
                        SenderAccountLabel(account: account).tag(account.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                fromLabel
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
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay { fieldOutline(isFocused: focus == .from) }
            .help(model.fromEmail)
            .accessibilityLabel("From")
            .accessibilityValue(model.fromEmail)
        } else {
            fromLabel
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.vertical, Tokens.Space.s1_5)
                .frame(minHeight: Tokens.Control.iconButton)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .overlay { fieldOutline(isFocused: false) }
                .help("Replies and Gmail drafts stay with their original account.")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("From \(model.fromEmail)")
        }
    }

    private var fromLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            fieldLabel("From:")
            Group {
                if let account = model.accountChoices.first(where: { $0.id == model.draft?.accountID }) {
                    SenderAccountLabel(account: account)
                } else {
                    Text(model.fromEmail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: Tokens.Popover.width, alignment: .leading)
            Spacer(minLength: 0)
            Image(systemName: model.canChangeAccount ? "chevron.up.chevron.down" : "lock")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
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
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .fill(Tokens.Surface.primary)
                .contentShape(Rectangle())
                .onTapGesture { focusField(field) }
                .accessibilityHidden(true)
        }
        .overlay { fieldOutline(isFocused: isFocused) }
    }

    private func fieldOutline(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .strokeBorder(
                isFocused ? Color.accentColor : (contrast == .increased ? .primary : Tokens.Surface.border),
                lineWidth: isFocused ? Tokens.Border.focus : Tokens.Border.hairline
            )
            .allowsHitTesting(false)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: Tokens.Space.s16, alignment: .leading)
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
        }
    }

    private func recipientField(_ label: String, addresses: Binding<[EmailAddress]>, field: Field) -> some View {
        // Never ask the token field itself; see `RecipientField.firstBaseline`.
        let baseline = RecipientField.firstBaseline
        return RecipientField(
            label: label,
            addresses: addresses,
            requestsFocus: Binding(
                get: { recipientFocus == field },
                set: { if !$0, recipientFocus == field { recipientFocus = nil } }
            ),
            isEditable: model.isEditable,
            onFocusChange: { isFocused in
                if isFocused {
                    focusedRecipient = field
                } else if focusedRecipient == field {
                    focusedRecipient = nil
                }
            }
        ) { [model] text in
            await model.suggestions(for: text)
        }
        .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }

    private func reveal(_ field: Field) {
        switch field {
        case .cc: model.showsCc = true
        case .bcc: model.showsBcc = true
        case .to, .subject, .from: break
        }
        focusField(field)
    }

    // MARK: Quoted text

    private func quotedText(_ quote: String) -> some View {
        let noun = model.draft?.kind == .forward ? "Forwarded Message" : "Quoted Text"
        return VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Divider()
            Button {
                showsQuote.toggle()
            } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsQuote ? 90 : 0))
                    Text(noun)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "text.quote")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Tokens.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Included unchanged below your message, even when hidden.")
            .accessibilityLabel(showsQuote ? "Hide \(noun)" : "Show \(noun)")
            .accessibilityValue(showsQuote ? "Expanded" : "Collapsed")
            .padding(.horizontal, Tokens.Space.s4)
            if showsQuote {
                ScrollView {
                    Text(quote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.s4)
                }
                .frame(minHeight: Tokens.Space.s16, maxHeight: Tokens.Layout.quoteMaxHeight)
                .transition(.opacity)
            }
        }
        .padding(.bottom, Tokens.Space.s1)
        .background(Tokens.Surface.muted)
        .ternAnimation(value: showsQuote)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showsFormatting) {
                Label("Formatting", systemImage: "textformat")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(showsFormatting ? "Hide Formatting" : "Show Formatting")
            .accessibilityLabel("Formatting")
            .accessibilityValue(showsFormatting ? "Expanded" : "Collapsed")
            .disabled(!model.isEditable)
            // Cmd-K must also work while the formatting bar is hidden.
            .popover(isPresented: $model.isEditingLink, arrowEdge: .bottom) {
                LinkEditor(existingURL: model.format.linkURL, width: Tokens.Layout.linkEditorWidth) { url in
                    model.editor?.setLink(url)
                }
            }
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
            Button {
                Task { await model.discard() }
            } label: {
                Label("Discard Draft", systemImage: "trash")
            }
            .help("Discard Draft")
            .disabled(!model.isEditable)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.send() }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Send (⇧⌘D)")
            .accessibilityLabel("Send")
            .disabled(!model.isEditable)
        }
    }

    private var formattingBar: some View {
        HStack(spacing: Tokens.Space.s2) {
            ControlGroup {
                formatToggle("Bold", systemImage: "bold", isOn: model.format.bold) { $0.toggleBold() }
                formatToggle("Italic", systemImage: "italic", isOn: model.format.italic) { $0.toggleItalic() }
                formatToggle("Underline", systemImage: "underline", isOn: model.format.underline) { $0.toggleUnderline() }
            }
            ControlGroup {
                formatToggle("Bulleted List", systemImage: "list.bullet", isOn: model.format.list == .bulleted) {
                    $0.toggleList(.bulleted)
                }
                formatToggle("Numbered List", systemImage: "list.number", isOn: model.format.list == .numbered) {
                    $0.toggleList(.numbered)
                }
            }
            Button {
                model.isEditingLink = true
            } label: {
                Label(model.format.link ? "Edit Link" : "Add Link", systemImage: "link")
            }
            .help(model.format.link ? "Edit Link" : "Add Link")
            .disabled(!model.canFormat)
            Spacer(minLength: 0)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s1)
        .background(Tokens.Surface.muted)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
    }

    private func formatToggle(
        _ title: String, systemImage: String, isOn: Bool, action: @escaping (any RichTextEditing) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in model.editor.map(action) })) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.button)
        .help(title)
        .disabled(!model.canFormat)
    }

    // MARK: Private

    private var isShowingAlert: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    /// A reply starts in the message; anything without recipients starts in To.
    private func placeFocus() async {
        guard !hasPlacedFocus, let draft = model.draft else { return }
        hasPlacedFocus = true
        // Let the fields and editor join the window first.
        await Task.yield()
        if draft.to.isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty {
            recipientFocus = .to
        } else if draft.subject.isEmpty {
            focus = .subject
        } else {
            model.editor?.focus()
        }
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
                .foregroundStyle(isError ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange))
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
private struct LinkEditor: View {
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
