import SwiftUI

struct ComposeQuoteEditor: View {
    let initialText: String
    let save: @MainActor (String) async -> Bool
    @State private var text: String
    @State private var isSaving = false
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    init(text: String, save: @escaping @MainActor (String) async -> Bool) {
        initialText = text
        _text = State(initialValue: text)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Edit Quoted Text").font(.headline)
            Text("Saving replaces the quotation's formatting with plain text.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .accessibilityLabel("Quoted text")
                .accessibilityIdentifier("compose-quote-text")
                .frame(minHeight: Tokens.Layout.quoteMaxHeight)
            if saveFailed {
                Text("Couldn't save the quotation. Try again.")
                    .foregroundStyle(Tokens.Status.error)
                    .ternTransition(.disclosure)
            }
            HStack {
                Button("Remove Quotation") { text = "" }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Changes") {
                    isSaving = true
                    Task {
                        if await save(text) { dismiss() }
                        else { saveFailed = true; isSaving = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text == initialText)
                .accessibilityIdentifier("compose-save-quote")
            }
        }
        .padding(Tokens.Space.s5)
        .frame(minWidth: Tokens.Sheet.smallWidth, idealWidth: Tokens.Layout.composeWidth)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .ternAnimation(value: saveFailed)
    }
}
