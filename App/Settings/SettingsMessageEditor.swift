import MessageContent
import Observation
import SwiftUI

/// Keeps unsupported or untouched Gmail HTML intact.
@MainActor @Observable
final class SettingsMessageDraft {
    var document: ComposeDocument
    let initialDocument: ComposeDocument
    let originalHTML: String?
    let originalPlainText: String?
    let isReadOnly: Bool
    var format = TextFormat()
    var isFocused = false
    var showsLink = false
    @ObservationIgnored var editor: (any RichTextEditing)?

    init(html: String?, plainText: String? = nil) {
        originalHTML = html
        originalPlainText = plainText
        if let html, !html.isEmpty {
            let imported = HTMLImporter.importHTML(html, detachingQuote: false)
            document = imported.document
            initialDocument = imported.document
            isReadOnly = imported.droppedFormatting
        } else {
            let plainDocument = ComposeDocument(plainText: plainText ?? "")
            document = plainDocument
            initialDocument = plainDocument
            isReadOnly = false
        }
    }

    var changed: Bool { !isReadOnly && document != initialDocument }
    var savedHTML: String? { changed ? document.html() : originalHTML }
    var savedPlainText: String? { changed ? document.plainText() : originalPlainText }
}

struct SettingsEditorFocus {
    let editor: any RichTextEditing
    let format: TextFormat
    let editLink: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var settingsEditor: SettingsEditorFocus?
}

struct SettingsMessageEditor: View {
    @Bindable var draft: SettingsMessageDraft
    let isEditable: Bool
    @State private var linkText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if draft.isReadOnly {
                Text("This message has formatting Tern can't edit. Its original HTML stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary).padding(Tokens.Space.s3)
            }
            FormatBar(format: draft.format, isEnabled: canFormat, editor: draft.editor) {
                linkText = draft.format.linkURL?.absoluteString ?? ""
                draft.showsLink = true
            }
            RichTextEditor(document: $draft.document, format: $draft.format, isEditable: isEditable && !draft.isReadOnly) {
                draft.editor = $0
            } onAttach: { _ in } onFocusChange: { draft.isFocused = $0 }
            .frame(minHeight: Tokens.Layout.quoteMaxHeight)
        }
        .ternSurface(radius: Tokens.Radius.sm)
        .focusedValue(\.settingsEditor, focusedEditor)
        .popover(isPresented: $draft.showsLink) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Link").font(.headline)
                TextField("https://example.com", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Link URL")
                HStack(spacing: Tokens.Space.s2) {
                    Button("Remove Link") { draft.editor?.setLink(nil); draft.showsLink = false }
                    Spacer(minLength: 0)
                    Button("Cancel") { draft.showsLink = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        if let url = safeURL { draft.editor?.setLink(url); draft.showsLink = false }
                    }
                    .disabled(safeURL == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
            .padding(Tokens.Space.s3)
            .frame(width: Tokens.Layout.linkEditorWidth)
        }
    }

    private var canFormat: Bool { isEditable && !draft.isReadOnly && draft.isFocused }
    private var safeURL: URL? {
        guard let url = URL(string: linkText), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
    private var focusedEditor: SettingsEditorFocus? {
        guard canFormat, let editor = draft.editor else { return nil }
        return SettingsEditorFocus(editor: editor, format: draft.format) {
            linkText = draft.format.linkURL?.absoluteString ?? ""
            draft.showsLink = true
        }
    }
}
