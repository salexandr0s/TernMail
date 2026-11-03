import MessageContent
import SwiftUI

/// Header controls own their focus and avatars for the lifetime of one draft.
/// The parent retains only the last field for a move to another account.
struct ComposeHeader: View {
    typealias Field = ComposeView.Field
    @Bindable var model: ComposeModel
    @Binding var requestedFocus: Field?
    let onFocus: (Field) -> Void
    @Environment(\.addressAvatarContext) private var avatarContext
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = DomainLogoPreferences.defaultEnabled
    @State private var senderAvatars = SenderAvatarModels()
    @FocusState private var focus: Field?
    @State private var recipientFocus: Field?
    @State private var focusedRecipient: Field?
    @State private var subjectSelection: TextSelection?
    @State private var keepsSubjectText = false
    @State private var highlightsFrom = false

    private var senderAvatarIdentity: String {
        avatarContext.identity + "|\(showsLogos)|" + model.senderChoices.map(\.id).sorted().joined(separator: "|")
    }

    private func configureSenderAvatars() {
        senderAvatars.configure(senders: model.senderChoices, context: avatarContext, showsLogos: showsLogos)
    }

    var body: some View {
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
        .onChange(of: requestedFocus, initial: true) { _, field in
            guard let field else { return }
            keepsSubjectText = field == .subject
            reveal(field)
            requestedFocus = nil
        }
        .onChange(of: focus) { _, field in
            if let field { noteFocus(field) }
            if field == .subject, keepsSubjectText {
                keepsSubjectText = false
                subjectSelection = TextSelection(insertionPoint: model.content.subject.endIndex)
            }
        }
        .onAppear(perform: configureSenderAvatars)
        .onChange(of: senderAvatarIdentity) { _, _ in configureSenderAvatars() }
        .onDisappear { senderAvatars.stop() }
        .task(id: model.phase == .open ? model.senderChange : nil) { await highlightSenderChange() }
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
        if model.isEditable { onFocus(field) }
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

    private func reveal(_ field: Field) {
        switch field {
        case .cc: model.showsCc = true
        case .bcc: model.showsBcc = true
        case .to, .subject, .from, .message: break
        }
        focusField(field)
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
