import SwiftUI

/// Keeps save and send progress visible at every compose window width.
struct ComposeDraftStatus: View {
    let text: String?
    let isError: Bool
    let isWorking: Bool
    let hasUnsavedChanges: Bool
    let requestsReadReceipt: Bool
    let isEditable: Bool
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            if isWorking {
                ProgressView().controlSize(.mini)
            } else if !isError {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if isError {
                Button("Draft needs attention", systemImage: "exclamationmark.circle") { showsDetails = true }
                    .buttonStyle(.link)
                    .foregroundStyle(Tokens.Status.error)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(text ?? "View draft status")
                    .accessibilityIdentifier("compose-draft-status-details")
                    .popover(isPresented: $showsDetails) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                            Text("Draft status").font(.headline)
                            Text(text ?? "The draft needs your attention.")
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Tokens.Space.s4)
                        .frame(width: Tokens.Layout.linkEditorWidth)
                    }
            } else {
                Text(text ?? (hasUnsavedChanges ? "Draft · Not yet saved to Gmail" : "Draft"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .help(text ?? "Draft")
            }
            if requestsReadReceipt {
                Label("Read receipt requested", systemImage: "checkmark.message")
                    .labelStyle(.iconOnly)
                    .help("Read receipt requested")
            }
            if isEditable {
                Text("⇧⌘D to send")
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose-draft-status")
    }
}
