import SwiftUI

/// Formatting commands shared by message, signature and vacation editors.
struct FormatBar: View {
    let format: TextFormat
    let isEnabled: Bool
    let editor: (any RichTextEditing)?
    let onEditLink: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            ControlGroup {
                formatToggle("Bold", systemImage: "bold", isOn: format.bold) { $0.toggleBold() }
                formatToggle("Italic", systemImage: "italic", isOn: format.italic) { $0.toggleItalic() }
                formatToggle("Underline", systemImage: "underline", isOn: format.underline) { $0.toggleUnderline() }
            }
            ControlGroup {
                formatToggle("Bulleted List", systemImage: "list.bullet", isOn: format.list == .bulleted) { $0.toggleList(.bulleted) }
                formatToggle("Numbered List", systemImage: "list.number", isOn: format.list == .numbered) { $0.toggleList(.numbered) }
            }
            Button(action: onEditLink) {
                Label(format.link ? "Edit Link" : "Add Link", systemImage: "link")
            }
            .help(format.link ? "Edit Link" : "Add Link")
            .disabled(!isEnabled)
            Spacer(minLength: 0)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s1)
        .background(Tokens.Surface.muted)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
    }

    private func formatToggle(
        _ title: String, systemImage: String, isOn: Bool, action: @escaping (any RichTextEditing) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in editor.map(action) })) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.button)
        .help(title)
        .disabled(!isEnabled)
    }
}
