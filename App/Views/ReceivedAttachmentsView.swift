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
            HStack {
                Label(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments", systemImage: "paperclip")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if attachments.count > 1 {
                    Button("Save All…") { saveAll() }.font(.caption)
                        .disabled(!loading.isEmpty)
                }
            }
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
                        .help("Save \(attachment.filename)")
                        .accessibilityLabel("Save \(attachment.filename)")
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.forward.app") { act(attachment) { try await AttachmentActions.open($0) } }
                        Button("Open With…") { act(attachment) { try await AttachmentActions.openWith($0) } }
                        Button("Quick Look", systemImage: "eye") { preview(attachment) }
                            .labelStyle(.titleAndIcon)
                        Button("Save…", systemImage: "arrow.down.circle") { save(attachment) }
                            .labelStyle(.titleAndIcon)
                        Button("Copy", systemImage: "doc.on.doc") { act(attachment) { AttachmentActions.copy($0) } }
                    }
                    .disabled(loading.contains(attachment.id))
                }
            }
        }
        .padding(.top, Tokens.Space.s1)
        .quickLookPreview($previewURL)
        .protectAttachmentPreview(previewURL)
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
        act(attachment) { try await AttachmentActions.save($0, filename: attachment.filename) }
    }

    private func act(_ attachment: AttachmentRecord, operation: @escaping @MainActor (URL) async throws -> Void) {
        Task {
            guard let file = await download(attachment) else { return }
            do { try await operation(file) }
            catch { mailbox.notice = MailboxModel.Notice(message: "Couldn't open or save “\(attachment.filename)”. Try again.", isError: true) }
        }
    }

    private func saveAll() {
        Task {
            var files: [URL] = []
            for attachment in attachments {
                guard let file = await download(attachment) else { return }
                files.append(file)
            }
            do { try await AttachmentActions.saveAll(files) }
            catch { mailbox.notice = MailboxModel.Notice(message: "Couldn't save all attachments. Try another folder.", isError: true) }
        }
    }

    private func download(_ attachment: AttachmentRecord) async -> URL? {
        guard loading.insert(attachment.id).inserted else { return nil }
        defer { loading.remove(attachment.id) }
        return await mailbox.download(attachment)
    }
}
