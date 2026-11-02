import MessageContent
import SwiftUI

struct ComposeSignatureEditor: View {
    let apply: @MainActor (ComposeDocument) -> Void
    @State private var document: ComposeDocument
    @State private var format = TextFormat()
    @State private var editor: (any RichTextEditing)?
    @State private var isFocused = false
    @State private var showsLink = false
    private let droppedFormatting: Bool
    @Environment(\.dismiss) private var dismiss

    init(html: String?, apply: @escaping @MainActor (ComposeDocument) -> Void) {
        let imported = HTMLImporter.importHTML(html ?? "", detachingQuote: false)
        _document = State(initialValue: imported.document)
        droppedFormatting = imported.droppedFormatting
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Edit Signature for This Message").font(.headline)
            if droppedFormatting {
                Text("Saving keeps supported text formatting. Images, tables, and custom fonts are removed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            FormatBar(format: format, isEnabled: isFocused, editor: editor) { showsLink = true }
                .popover(isPresented: $showsLink) {
                    LinkEditor(existingURL: format.linkURL, width: Tokens.Layout.linkEditorWidth) { editor?.setLink($0) }
                }
            RichTextEditor(document: $document, format: $format, isEditable: true) { editor = $0 }
                onAttach: { _ in } onFocusChange: { isFocused = $0 }
                .frame(minHeight: Tokens.Layout.quoteMaxHeight)
                .accessibilityLabel("Message signature")
                .accessibilityIdentifier("compose-signature-text")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Signature") { apply(document); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("compose-save-signature")
            }
        }
        .padding(Tokens.Space.s5)
        .frame(minWidth: Tokens.Sheet.smallWidth, idealWidth: Tokens.Layout.composeWidth)
    }
}
