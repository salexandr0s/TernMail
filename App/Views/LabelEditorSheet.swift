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
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(
                title: title,
                systemImage: draft.icon,
                subtitle: "Click the icon to change it.",
                iconForeground: draft.color == nil ? .accentColor : previewForeground,
                iconBackground: previewBackground,
                iconAction: { isChoosingIcon = true },
                iconActionLabel: "Choose Label Icon"
            )
            .popover(isPresented: $isChoosingIcon, arrowEdge: .bottom) {
                LabelIconPicker(selection: $draft.icon) { isChoosingIcon = false }
            }

            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                fields
                Divider()
                LabelColorPicker(selection: $draft.color)
                preview
                Text("Name and color sync with Gmail. Icons stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.bottom, Tokens.Space.s5)

            PopupFooter {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isNameEmpty || problem != nil)
            }
        }
        .frame(width: Tokens.Sheet.smallWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { isNameFocused = true }
        .ternAnimation(value: problem)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Grid(alignment: .leading, horizontalSpacing: Tokens.Space.s3, verticalSpacing: Tokens.Space.s3) {
                GridRow {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Label name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .accessibilityLabel("Label name")
                        .accessibilityHint(problem ?? "")
                        .overlay {
                            if problem != nil {
                                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                    .strokeBorder(.red, lineWidth: Tokens.Border.hairline)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                GridRow {
                    Text("Nest under")
                        .foregroundStyle(.secondary)
                    Picker("Nest under", selection: $draft.parent) {
                        Text("None").tag(String?.none)
                        ForEach(parentChoices, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .labelsHidden()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(draft.parent ?? "None")
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var preview: some View {
        HStack(spacing: Tokens.Space.s3) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Label(isNameEmpty ? "Label name" : draft.fullName, systemImage: draft.icon)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s1_5)
                .foregroundStyle(previewForeground)
                .background(previewBackground, in: Capsule())
                .overlay { Capsule().strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                .help(isNameEmpty ? "Label name" : draft.fullName)
        }
    }
}
