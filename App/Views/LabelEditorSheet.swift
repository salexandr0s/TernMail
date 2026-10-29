import GmailAPI
import SwiftUI

/// New Label and Edit Label: a name, an optional parent and a color.
struct LabelEditorSheet: View {
    struct Draft: Equatable {
        var name: String
        var parent: String?
        var color: LabelColor?

        /// Gmail stores nesting in the name, as "Parent/Child".
        var fullName: String {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return parent.map { "\($0)/\(name)" } ?? name
        }
    }

    let title: String
    let saveTitle: String
    /// Full names of the labels this one may be nested under.
    let parentChoices: [String]
    /// A message when Gmail would refuse the full name, or nil.
    let validate: (String) -> String?
    let onSave: (Draft) -> Void
    let onCancel: () -> Void

    @State private var draft: Draft
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

    private var isNameEmpty: Bool {
        draft.name.allSatisfy(\.isWhitespace)
    }

    /// Shown once there's a name, so an empty field doesn't open with an error.
    private var problem: String? {
        isNameEmpty ? nil : validate(draft.fullName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "tag")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: Tokens.Control.avatarLarge, height: Tokens.Control.avatarLarge)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(title).font(.title3.weight(.semibold))
                }
            }
            .padding([.horizontal, .top], Tokens.Space.s6)

            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .focused($isNameFocused)
                        .accessibilityHint(problem ?? "Label name")
                    Picker("Nest under", selection: $draft.parent) {
                        Text("None").tag(String?.none)
                        ForEach(parentChoices, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    LabelColorGrid(selection: $draft.color)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Color")
                } footer: {
                    Text("Name and color sync with Gmail.")
                }
            }
            .formStyle(.grouped)
            .frame(
                minHeight: Tokens.Popover.maxListHeight,
                idealHeight: Tokens.Sheet.smallWidth,
                maxHeight: Tokens.Sheet.smallWidth
            )

            Divider()
            HStack(spacing: Tokens.Space.s3) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isNameEmpty || problem != nil)
            }
            .padding(Tokens.Space.s5)
            .background(Tokens.Surface.muted)
        }
        .frame(width: Tokens.Sheet.smallWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { isNameFocused = true }
        .ternAnimation(value: problem)
    }
}

/// The 8×8 grid of Gmail's label colors and a No Color choice.
struct LabelColorGrid: View {
    @Binding var selection: LabelColor?

    private static let rows: [[LabelColor]] = stride(from: 0, to: LabelColor.grid.count, by: 8).map {
        Array(LabelColor.grid[$0..<min($0 + 8, LabelColor.grid.count)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Grid(horizontalSpacing: Tokens.Space.s1, verticalSpacing: Tokens.Space.s1) {
                ForEach(Self.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(Self.rows[row].indices, id: \.self) { column in
                            swatch(Self.rows[row][column], name: Self.name(row: row, column: column))
                        }
                    }
                }
            }
            Button {
                selection = nil
            } label: {
                Label("No Color", systemImage: selection == nil ? "checkmark.circle" : "circle.slash")
            }
            .buttonStyle(.link)
            .accessibilityAddTraits(selection == nil ? .isSelected : [])
        }
    }

    private func swatch(_ color: LabelColor, name: String) -> some View {
        let isSelected = selection == color
        return Button {
            selection = color
        } label: {
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .fill(Color(gmailHex: color.backgroundColor) ?? .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(.separator)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(gmailHex: color.textColor) ?? .primary)
                    }
                }
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .padding(Tokens.Space.s1)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Tokens.Radius.md)
                            .strokeBorder(.tint, lineWidth: Tokens.Border.focus)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .ternAnimation(value: isSelected)
    }

    /// The first row is grays. In the other rows each column is a hue and each
    /// row a shade, as Gmail lays the colors out.
    static func name(row: Int, column: Int) -> String {
        let grays = ["Black", "Darkest gray", "Dark gray", "Gray", "Light gray", "Lighter gray", "Lightest gray", "White"]
        let hues = ["red", "orange", "yellow", "green", "mint", "blue", "purple", "pink"]
        let shades = ["Bright", "Palest", "Pale", "Medium", "Deep", "Dark", "Darkest"]
        guard row > 0 else { return grays[column % grays.count] }
        return "\(shades[(row - 1) % shades.count]) \(hues[column % hues.count])"
    }
}
