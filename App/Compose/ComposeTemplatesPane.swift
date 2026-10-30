import MailStore
import MessageContent
import SwiftUI

struct ComposeTemplatesPane: View {
    let store: AccountStore
    @State private var templates: [ComposeTemplate] = []
    @State private var selection: String?
    @State private var name = ""
    @State private var document = ComposeDocument()
    @State private var format = TextFormat()
    @State private var editor: (any RichTextEditing)?
    @State private var focused = false
    @State private var editingLink = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                Picker("Template", selection: $selection) {
                    Text("New template").tag(String?.none)
                    ForEach(templates) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("New") { selection = nil; name = ""; document = ComposeDocument() }
            }
            TextField("Name", text: $name)
            FormatBar(format: format, isEnabled: focused, editor: editor) { editingLink = true }
                .popover(isPresented: $editingLink) {
                    LinkEditor(existingURL: format.linkURL, width: Tokens.Layout.linkEditorWidth) { editor?.setLink($0) }
                }
            RichTextEditor(document: $document, format: $format, isEditable: true) { editor = $0 }
                onAttach: { _ in error = "Templates hold text and formatting. Add files when composing a message." }
                onFocusChange: { focused = $0 }
                .frame(minHeight: Tokens.Space.s16 * 3)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Delete", role: .destructive) {
                    guard let selection else { return }
                    Task { await delete(selection) }
                }.disabled(selection == nil)
                Spacer()
                Button("Save Template") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Tokens.Space.s4)
        .task { await reload() }
        .focusedValue(\.settingsEditor, focusedEditor)
        .onChange(of: selection) { _, id in
            if let template = templates.first(where: { $0.id == id }) { name = template.name; document = template.document }
            else { name = ""; document = ComposeDocument() }
        }
    }

    private func reload() async {
        do { templates = try await store.composeTemplates() } catch { self.error = "Couldn't load templates." }
    }
    private func save() async {
        let template = ComposeTemplate(id: selection ?? UUID().uuidString, name: name, document: document)
        do {
            try await store.saveComposeTemplate(template); await reload(); selection = template.id; error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        }
        catch { self.error = "Couldn't save this template." }
    }
    private func delete(_ id: String) async {
        do {
            try await store.deleteComposeTemplate(id: id); await reload(); selection = nil; error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        }
        catch { self.error = "Couldn't delete this template." }
    }

    private var focusedEditor: SettingsEditorFocus? {
        guard focused, let editor else { return nil }
        return SettingsEditorFocus(editor: editor, format: format) { editingLink = true }
    }
}
