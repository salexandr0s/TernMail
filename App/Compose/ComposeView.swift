import MailStore
import MessageContent
import SwiftUI

/// A compose window's content: waits for the mailbox, then edits one draft.
struct ComposeWindow: View {
    static let sceneID = "compose"

    let localDraftID: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let localDraftID, let mailbox = app.mailbox {
                ComposeView(localDraftID: localDraftID, mailbox: mailbox)
                    // Another account's mailbox needs its own model.
                    .id(ObjectIdentifier(mailbox))
            } else {
                ProgressView()
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
    static let minWidth: CGFloat = 480
    static let minHeight: CGFloat = 360
    private static let quoteHeight: CGFloat = 180
    private static let linkFieldWidth: CGFloat = 280

    private enum Field: Hashable {
        case to, cc, bcc, subject
    }

    @State private var model: ComposeModel
    @State private var showsQuote = false
    @State private var isEditingLink = false
    @State private var isChoosingFiles = false
    @State private var hasPlacedFocus = false
    @FocusState private var focus: Field?
    /// The recipient field to move the cursor to. Token fields are AppKit
    /// views, which `focus` can't reach.
    @State private var recipientFocus: Field?
    @Environment(\.dismiss) private var dismiss

    init(localDraftID: String, mailbox: MailboxModel) {
        _model = State(initialValue: ComposeModel(localDraftID: localDraftID, mailbox: mailbox))
    }

    var body: some View {
        Group {
            if model.phase == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.status.flatMap { $0.isError ? nil : $0.text } ?? "")
        .toolbar { toolbar }
        .alert(model.alert ?? "", isPresented: isShowingAlert) {
            Button("OK") {}
        }
        .task { model.start() }
        .task(id: model.phase) {
            switch model.phase {
            case .loading: break
            case .open: await placeFocus()
            case .closed: dismiss()
            }
        }
        .onDisappear { model.windowClosed() }
    }

    private var form: some View {
        VStack(spacing: 0) {
            if model.droppedFormatting {
                Banner(
                    systemImage: "exclamationmark.triangle",
                    text: "This draft has formatting Tern can't edit, such as tables or fonts. If you change it, Tern keeps only bold, italic, underline, links and lists."
                ) {
                    model.droppedFormatting = false
                }
            }
            if let status = model.status, status.isError {
                Banner(systemImage: "exclamationmark.circle", text: status.text, isError: true)
            }
            header
            Divider()
            RichTextEditor(
                document: $model.content.body,
                format: $model.format,
                isEditable: model.isEditable
            ) { model.editor = $0 } onAttach: { model.attach($0) }
            if !model.attachments.isEmpty {
                AttachmentStrip(attachments: model.attachments, isEditable: model.isEditable) {
                    model.removeAttachment($0)
                }
            }
            if let quote = model.draft?.quotedPlainText, !quote.isEmpty {
                quotedText(quote)
            }
        }
        // Files dropped outside the message, which handles its own drops.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard model.isEditable, !files.isEmpty else { return false }
            model.attach(files.map(Attachable.file))
            return true
        }
        .fileImporter(isPresented: $isChoosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls.map(Attachable.file)) }
        }
    }

    // MARK: Header

    private var header: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Space.s2, verticalSpacing: 0) {
            GridRow {
                fieldLabel("To:")
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    recipientField("To", addresses: $model.content.to, field: .to)
                    if !model.showsCc {
                        Button("Cc") { reveal(.cc) }
                            .help("Add Cc recipients")
                    }
                    if !model.showsBcc {
                        Button("Bcc") { reveal(.bcc) }
                            .help("Add Bcc recipients")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.vertical, Tokens.Space.s2)
            }
            if model.showsCc {
                Divider()
                GridRow {
                    fieldLabel("Cc:")
                    recipientField("Cc", addresses: $model.content.cc, field: .cc)
                        .padding(.vertical, Tokens.Space.s2)
                }
            }
            if model.showsBcc {
                Divider()
                GridRow {
                    fieldLabel("Bcc:")
                    recipientField("Bcc", addresses: $model.content.bcc, field: .bcc)
                        .padding(.vertical, Tokens.Space.s2)
                }
            }
            Divider()
            GridRow {
                fieldLabel("Subject:")
                TextField("Subject", text: $model.content.subject)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focus, equals: .subject)
                    .padding(.vertical, Tokens.Space.s2)
            }
        }
        .disabled(!model.isEditable)
        .padding(.horizontal, Tokens.Space.s4)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(true)
    }

    private func recipientField(_ label: String, addresses: Binding<[EmailAddress]>, field: Field) -> some View {
        RecipientField(
            label: label,
            addresses: addresses,
            requestsFocus: Binding(
                get: { recipientFocus == field },
                set: { if !$0, recipientFocus == field { recipientFocus = nil } }
            ),
            isEditable: model.isEditable
        ) { [model] text in
            await model.suggestions(for: text)
        }
    }

    private func reveal(_ field: Field) {
        switch field {
        case .cc: model.showsCc = true
        case .bcc: model.showsBcc = true
        case .to, .subject: break
        }
        recipientFocus = field
    }

    // MARK: Quoted text

    private func quotedText(_ quote: String) -> some View {
        let noun = model.draft?.kind == .forward ? "Forwarded Message" : "Quoted Text"
        return VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Divider()
            Button(showsQuote ? "Hide \(noun)" : "Show \(noun)") {
                withAnimation(Tokens.Motion.standard()) { showsQuote.toggle() }
            }
            .buttonStyle(.borderless)
            .help("It's sent below your message as it is.")
            .padding(.horizontal, Tokens.Space.s4)
            if showsQuote {
                ScrollView {
                    Text(quote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.s4)
                }
                .frame(maxHeight: Self.quoteHeight)
                .transition(.opacity)
            }
        }
        .padding(.bottom, Tokens.Space.s2)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.send() }
            } label: {
                Label("Send", systemImage: "paperplane")
            }
            .help("Send")
            .disabled(!model.isEditable)
        }
        ToolbarItemGroup {
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
                isEditingLink = true
            } label: {
                Label(model.format.link ? "Edit Link" : "Add Link", systemImage: "link")
            }
            .help(model.format.link ? "Edit Link" : "Add Link")
            .disabled(!model.isEditable)
            .popover(isPresented: $isEditingLink, arrowEdge: .bottom) {
                LinkEditor(hasLink: model.format.link, width: Self.linkFieldWidth) { url in
                    model.editor?.setLink(url)
                }
            }
        }
        ToolbarItem {
            Button {
                isChoosingFiles = true
            } label: {
                Label("Attach Files", systemImage: "paperclip")
            }
            .help("Attach Files")
            .disabled(!model.isEditable)
        }
        ToolbarItem {
            Button {
                Task { await model.discard() }
            } label: {
                Label("Discard Draft", systemImage: "trash")
            }
            .help("Discard Draft")
            .disabled(!model.isEditable)
        }
    }

    private func formatToggle(
        _ title: String, systemImage: String, isOn: Bool, action: @escaping (any RichTextEditing) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in model.editor.map(action) })) {
            Label(title, systemImage: systemImage)
        }
        .help(title)
        .disabled(!model.isEditable)
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
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
        .background(.fill.tertiary)
        .accessibilityElement(children: .combine)
    }
}

/// Asks for a link's address.
private struct LinkEditor: View {
    let hasLink: Bool
    let width: CGFloat
    let apply: (URL?) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            TextField("Web or email address", text: $text)
                .frame(width: width)
                .onSubmit(add)
            HStack(spacing: Tokens.Space.s2) {
                if hasLink {
                    Button("Remove Link") {
                        apply(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Link", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ComposeModel.linkURL(from: text) == nil)
            }
        }
        .padding(Tokens.Space.s4)
    }

    private func add() {
        guard let url = ComposeModel.linkURL(from: text) else { return }
        apply(url)
        dismiss()
    }
}
