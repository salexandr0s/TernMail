import AppKit
import MailStore
import MessageContent
import SwiftUI
import UniformTypeIdentifiers

/// Show Original opens the raw RFC 822 message in its own window. Esc and
/// Close both dismiss it.
struct OriginalMessageWindow: View {
    static let sceneID = "original-message"
    private static let previewLimit = 2 * 1_024 * 1_024

    let link: MailLink?
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var bytes: Data?
    @State private var subject = ""
    @State private var failure: String?
    @State private var saveFailure: String?

    var body: some View {
        Group {
            if let bytes {
                OriginalMessageText(bytes: bytes, limit: Self.previewLimit)
            } else if let failure {
                TernEmptyState(title: "Couldn't Load the Original", systemImage: "doc.plaintext", message: failure)
            } else {
                ProgressView("Loading original message…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(subject.isEmpty ? "Original Message" : subject)
        .navigationSubtitle(subject.isEmpty ? "" : "Original Message")
        .frame(minWidth: Tokens.Layout.conversationMinWidth, minHeight: Tokens.Layout.conversationMinHeight)
        .toolbar {
            ToolbarItemGroup {
                Button("Copy", systemImage: "doc.on.doc") { copy() }
                    .help("Copy the complete original")
                    .disabled(bytes == nil)
                Button("Save…", systemImage: "arrow.down.circle") { Task { await save() } }
                    .help("Save the complete original as an .eml file")
                    .disabled(bytes == nil)
            }
        }
        .alert("Couldn't Save Original", isPresented: $saveFailure.isPresent()) {
            Button("OK", role: .cancel) { saveFailure = nil }
        } message: {
            Text(saveFailure ?? "Choose another location and try again.")
        }
        .onExitCommand { dismissWindow() }
        .task(id: link) { await load() }
    }

    private func load() async {
        bytes = nil
        failure = nil
        guard let link, let messageID = link.messageID, let mailbox = app.mailbox, let owner = mailbox.account(id: link.accountID) else {
            failure = "Sign in to its account, then open the message again."
            return
        }
        do {
            subject = try await mailbox.cache.read { try $0.message(id: messageID, accountID: link.accountID)?.subject } ?? ""
            let data = try await owner.engine.rawMessage(id: messageID)
            guard !Task.isCancelled else { return }
            bytes = data
        } catch is CancellationError {
        } catch {
            failure = "Check your connection and try again."
        }
    }

    private func copy() {
        guard let bytes else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(bytes, forType: NSPasteboard.PasteboardType("public.rfc822-message"))
        NSPasteboard.general.setString(String(decoding: bytes, as: UTF8.self), forType: .string)
    }

    private func save() async {
        guard let bytes else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]
        panel.nameFieldStringValue = AttachmentFileExport.safeFilename(subject.isEmpty ? "Original Message" : subject) + ".eml"
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        do { try bytes.write(to: url, options: .atomic) }
        catch { saveFailure = "Choose a writable location with enough free space, then try again." }
    }
}

/// The first part of the source in a monospaced, selectable view. Copy and
/// Save work on the whole original.
private struct OriginalMessageText: View {
    let bytes: Data
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ScrollView([.horizontal, .vertical]) {
                Text(String(decoding: bytes.prefix(limit), as: UTF8.self))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Tokens.Space.s4)
            }
            if bytes.count > limit {
                Text("Showing the first 2 MB. Copy and Save include the complete original.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], Tokens.Space.s4)
            }
        }
    }
}
