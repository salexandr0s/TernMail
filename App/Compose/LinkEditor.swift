import SwiftUI

/// Asks for a link's address.
struct LinkEditor: View {
    let existingURL: URL?
    let width: CGFloat
    let apply: (URL?) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var hasLink: Bool { existingURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(title: hasLink ? "Edit Link" : "Add Link", systemImage: "link")
            TextField("Web or email address", text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Link address")
                .focused($isFocused)
                .onSubmit(add)
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s5)
            PopupFooter {
                if hasLink {
                    Button("Remove Link") {
                        apply(nil)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(hasLink ? "Update Link" : "Add Link", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ComposeModel.linkURL(from: text) == nil)
            }
        }
        .frame(width: width)
        .onAppear {
            text = existingURL?.absoluteString ?? ""
            isFocused = true
        }
    }

    private func add() {
        guard let url = ComposeModel.linkURL(from: text) else { return }
        apply(url)
        dismiss()
    }
}
