import GmailAPI
import SwiftUI

/// Name and color sync with Gmail; the icon is a local preference.
struct LabelEditorSheet: View {
    struct Draft: Equatable {
        var name: String
        var parent: String?
        var color: LabelColor?
        var icon = "tag"

        /// Gmail stores nesting in the name, as "Parent/Child".
        var fullName: String {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return parent.map { "\($0)/\(name)" } ?? name
        }
    }

    let title: String
    let saveTitle: String
    let parentChoices: [String]
    let validate: (String) -> String?
    let onSave: (Draft) -> Void
    let onCancel: () -> Void

    @State private var draft: Draft
    @State private var isChoosingIcon = false
    @FocusState private var isNameFocused: Bool

    init(
        title: String,
        saveTitle: String,
        draft: Draft,
        parentChoices: [String],
        validate: @escaping (String) -> String?,
        onSave: @escaping (Draft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.parentChoices = parentChoices
        self.validate = validate
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
    }

    private var isNameEmpty: Bool { draft.name.allSatisfy(\.isWhitespace) }
    private var problem: String? { isNameEmpty ? nil : validate(draft.fullName) }
    private var previewBackground: Color {
        Color(gmailHex: draft.color?.backgroundColor) ?? Tokens.Surface.muted
    }
    private var previewForeground: Color {
        Color(gmailHex: draft.color?.textColor) ?? .primary
    }

    var body: some View {
        SettingsEditorSheet(title: title, width: Tokens.Settings.editorWideWidth,
                            messages: problem.map { [$0] } ?? []) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                fields
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    preview
                    Divider()
                    LabelColorPicker(selection: $draft.color)
                }
                .padding(Tokens.Space.s4)
                .ternSurface(style: .grouped)
                Text("Name and color sync with Gmail. Icons stay on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(saveTitle) { onSave(draft) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isNameEmpty || problem != nil)
        }
        .onAppear { isNameFocused = true }
        .ternAnimation(value: problem)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Name").font(.callout.bold()).foregroundStyle(.secondary)
                TextField("Label name", text: $draft.name)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
                    .accessibilityLabel("Label name")
                    .accessibilityHint(problem ?? "")
            }
            Divider()
            HStack(spacing: Tokens.Space.s3) {
                Text("Nest Under").font(.callout.bold()).foregroundStyle(.secondary)
                Picker("Nest under", selection: $draft.parent) {
                    Text("None").tag(String?.none)
                    ForEach(parentChoices, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                .labelsHidden()
                .controlSize(.large)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(draft.parent ?? "None")
            }
        }
        .padding(Tokens.Space.s4)
        .ternSurface(style: .grouped)
        .ternOutline(radius: Tokens.Radius.lg,
                     focus: problem != nil ? Tokens.Status.error : isNameFocused ? .accentColor : nil)
    }

    private var preview: some View {
        HStack(spacing: Tokens.Space.s3) {
            Button { isChoosingIcon = true } label: {
                Image(systemName: draft.icon)
                    .font(.title2)
                    .foregroundStyle(draft.color == nil ? .accentColor : previewForeground)
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .background(previewBackground, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .ternOutline(radius: Tokens.Radius.md)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose Label Icon")
            .help("Choose Label Icon")
            .popover(isPresented: $isChoosingIcon, arrowEdge: .bottom) {
                LabelIconPicker(selection: $draft.icon) { isChoosingIcon = false }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                Text(isNameEmpty ? "Label name" : draft.fullName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(isNameEmpty ? "Label name" : draft.fullName)
                Button("Change Icon…") { isChoosingIcon = true }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 0)
            Text("Preview").font(.caption).foregroundStyle(.secondary)
        }
    }
}
