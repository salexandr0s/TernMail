import AppKit
import MailStore
import SwiftUI
import UniformTypeIdentifiers

struct OriginalMessage: Identifiable {
    let id = UUID()
    let record: MessageRecord
    let bytes: Data
}

struct OriginalMessageView: View {
    let message: OriginalMessage
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(spacing: Tokens.Space.s3) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Original message").font(.headline)
                    Text(message.record.subject).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { copy() }
                Button("Save…") { save() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(String(decoding: message.bytes.prefix(2 * 1_024 * 1_024), as: UTF8.self))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if message.bytes.count > 2 * 1_024 * 1_024 {
                Text("Showing the first 2 MB. Copy and Save include the complete original.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(Tokens.Space.s4)
        .frame(minWidth: Tokens.Layout.readableWidth, minHeight: Tokens.Layout.shortcutsHeight)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(message.bytes, forType: NSPasteboard.PasteboardType("public.rfc822-message"))
        NSPasteboard.general.setString(String(decoding: message.bytes, as: UTF8.self), forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]
        panel.nameFieldStringValue = "Original Message.eml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try message.bytes.write(to: url, options: .atomic) }
        catch { self.error = "The original message could not be saved." }
    }
}
