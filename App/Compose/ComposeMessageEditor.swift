import SwiftUI

/// Owns the native writing surface and link popover without owning the draft.
struct ComposeMessageEditor: View {
    @Bindable var model: ComposeModel
    @Binding var isFileDropTargeted: Bool

    var body: some View {
        RichTextEditor(
            document: $model.content.body,
            format: $model.format,
            isEditable: model.isEditable,
            font: model.content.composeFont,
            inlineImages: model.inlineImageData,
            onDropFiles: { model.attach($0.map(Attachable.dropped)) },
            onFileDropTargetChange: { isFileDropTargeted = $0 }
        ) { model.editor = $0 } onAttach: { model.attach($0, inlineImages: true) } onFocusChange: { model.isEditingMessage = $0 }
        .overlay(alignment: .topLeading) {
            if model.content.body.isPlainTextEmpty {
                Text("Write your message…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, Tokens.Compose.gutter + Tokens.Border.hairline)
                    .padding(.top, Tokens.Space.s3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Tokens.Layout.editorMinHeight)
        // Cmd-K must also work while the formatting bar is hidden. The
        // popover points at the selection, where the link goes.
        .popover(isPresented: $model.isEditingLink, attachmentAnchor: linkAnchor, arrowEdge: .bottom) {
            LinkEditor(existingURL: model.format.linkURL, width: Tokens.Layout.linkEditorWidth) { url in
                model.editor?.setLink(url)
            }
        }
    }

    /// Where the link popover points: the text it links, or the whole editor
    /// when the selection isn't known.
    private var linkAnchor: PopoverAttachmentAnchor {
        model.linkAnchor.map { .rect(.rect($0)) } ?? .rect(.bounds)
    }
}
