import AppKit
import MailStore
import QuickLook
import SwiftUI

/// A received message's files. Clicking one opens it in Quick Look, and Save
/// copies it to a folder you pick. Each downloads the first time it's opened.
struct ReceivedAttachmentsView: View {
    let attachments: [AttachmentRecord]
    let mailbox: MailboxModel

    @State private var loading: Set<String> = []
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Label(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments", systemImage: "paperclip")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: Tokens.Space.s2) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        filename: attachment.filename,
                        size: attachment.size,
                        isLoading: loading.contains(attachment.id),
                        open: { preview(attachment) }
                    ) {
                        Button {
                            save(attachment)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(loading.contains(attachment.id))
                        .help("Save \(attachment.filename)")
                        .accessibilityLabel("Save \(attachment.filename)")
                    }
                    .contextMenu {
                        Button("Quick Look", systemImage: "eye") { preview(attachment) }
                            .labelStyle(.titleAndIcon)
                        Button("Save…", systemImage: "arrow.down.circle") { save(attachment) }
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .padding(.top, Tokens.Space.s1)
        .quickLookPreview($previewURL)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }

    private func preview(_ attachment: AttachmentRecord) {
        Task {
            guard let file = await download(attachment) else { return }
            previewURL = file
        }
    }

    private func save(_ attachment: AttachmentRecord) {
        Task {
            guard let file = await download(attachment) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.lastPathComponent
            panel.canCreateDirectories = true
            let response = if let window = NSApp.keyWindow {
                await panel.beginSheetModal(for: window)
            } else {
                await panel.begin()
            }
            guard response == .OK, let destination = panel.url else { return }
            do {
                // The panel already asked before replacing a file.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: file, to: destination)
            } catch {
                mailbox.notice = MailboxModel.Notice(message: "Tern couldn't save “\(attachment.filename)” there.", isError: true)
            }
        }
    }

    private func download(_ attachment: AttachmentRecord) async -> URL? {
        guard loading.insert(attachment.id).inserted else { return nil }
        defer { loading.remove(attachment.id) }
        return await mailbox.download(attachment)
    }
}
