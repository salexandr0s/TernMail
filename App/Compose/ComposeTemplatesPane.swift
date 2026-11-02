import MailStore
import MessageContent
import SwiftUI

struct ComposeTemplatesPane: View {
    let store: AccountStore
    @Environment(SettingsUnsavedChanges.self) private var unsaved
    @State private var baselineName = ""
    @State private var baselineDocument = ComposeDocument()
    @State private var isSaving = false
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
        SettingsPage {
            Section {
                ComposeLibraryPicker(title: "Saved templates", newItemLabel: "Create a new template",
                    symbol: "doc.text", identifierPrefix: "compose-template",
                    items: templates.map { .init(id: $0.id, name: $0.name) }, selection: guardedSelection) {
                    unsaved.request { load(nil) }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Template name", text: $name, prompt: Text("Template name"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(Tokens.Workspace.pageTitle)
                        .padding(Tokens.Space.s4)
                        .accessibilityIdentifier("compose-template-name")
                    Divider()
                    FormatBar(format: format, isEnabled: focused && !isSaving, editor: editor) { editingLink = true }
                        .popover(isPresented: $editingLink) {
                            LinkEditor(existingURL: format.linkURL, width: Tokens.Layout.linkEditorWidth) { editor?.setLink($0) }
                        }
                    RichTextEditor(document: $document, format: $format, isEditable: !isSaving) { editor = $0 }
                        onAttach: { _ in error = "Templates hold text and formatting. Add files when composing a message." }
                        onFocusChange: { focused = $0 }
                        .frame(minHeight: Tokens.Layout.quoteMaxHeight)
                }
                .ternSurface(radius: Tokens.Radius.sm)
                .accessibilityLabel("Template message")
            } header: {
                Text(selection == nil ? "New template" : "Edit template")
            } footer: {
                Text("Templates hold text and formatting. Add attachments when composing a message.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsFooter { saveBar } }
        .task { await reload() }
        .focusedValue(\.settingsEditor, focusedEditor)
        .disabled(isSaving)
        .onChange(of: hasChanges, initial: true) { _, _ in updateUnsaved() }
        .onDisappear { unsaved.clear() }
    }

    private var hasChanges: Bool { name != baselineName || document != baselineDocument }

    private var guardedSelection: Binding<String?> {
        Binding(get: { selection }, set: { id in
            guard id != selection else { return }
            unsaved.request { load(id) }
        })
    }

    private func load(_ id: String?) {
        let template = templates.first { $0.id == id }
        selection = template?.id
        name = template?.name ?? ""
        document = template?.document ?? ComposeDocument()
        baselineName = name
        baselineDocument = document
        updateUnsaved()
    }

    private func updateUnsaved() {
        if hasChanges { unsaved.set("template") } else { unsaved.clear() }
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if let error { SettingsErrorLabel(error) }
            HStack(spacing: Tokens.Space.s2) {
                Button("Delete Template", role: .destructive) {
                    guard let selection else { return }
                    unsaved.request { Task { await delete(selection) } }
                }
                .disabled(selection == nil)
                Spacer(minLength: Tokens.Space.s2)
                Button("Save Template") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func reload() async {
        do { templates = try await store.composeTemplates() } catch { self.error = "Couldn't load templates." }
    }
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let template = ComposeTemplate(id: selection ?? UUID().uuidString, name: name, document: document)
        do {
            try await store.saveComposeTemplate(template)
            templates.removeAll { $0.id == template.id }
            templates.append(template)
            load(template.id)
            error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        }
        catch { self.error = "Couldn't save this template." }
    }
    private func delete(_ id: String) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.deleteComposeTemplate(id: id)
            templates.removeAll { $0.id == id }
            load(nil)
            error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        }
        catch { self.error = "Couldn't delete this template." }
    }

    private var focusedEditor: SettingsEditorFocus? {
        guard focused, !isSaving, let editor else { return nil }
        return SettingsEditorFocus(editor: editor, format: format) { editingLink = true }
    }
}
