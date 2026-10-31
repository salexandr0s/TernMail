import AppKit
import MailStore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A received message's files. Clicking one opens it in Quick Look, where the
/// arrow keys page through the message's other files. Save copies it to a
/// folder you pick, and a chip drags out as the file itself. Each downloads
/// the first time it's used.
struct ReceivedAttachmentsView: View {
    let attachments: [AttachmentRecord]
    let mailbox: MailboxModel

    /// A second request for a file waits for its download instead of starting another.
    @State private var downloads = InFlightTasks<String, URL?>()
    @State private var isSavingAll = false
    @State private var previewRequest: UUID?
    @State private var previewURL: URL?
    @State private var previewItems: [URL] = []
    /// Where Save… put each file, for Show in Finder.
    @State private var savedFiles: [String: URL] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack {
                Label(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments", systemImage: "paperclip")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if attachments.count > 1 {
                    Button("Save All…") { saveAll() }.font(.callout)
                        .disabled(isSavingAll)
                }
            }
            FlowLayout(spacing: Tokens.Space.s2) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        filename: attachment.filename,
                        size: attachment.size,
                        isLoading: downloads.isRunning(attachment.id),
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
                    .draggable(AttachmentFileItem(attachment: attachment, mailbox: mailbox))
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.forward.app") { act(attachment) { try await AttachmentActions.open($0) } }
                        Button("Open With…") { act(attachment) { try await AttachmentActions.openWith($0) } }
                        Button("Quick Look", systemImage: "eye") { preview(attachment) }
                            .labelStyle(.titleAndIcon)
                        Divider()
                        Button("Save…", systemImage: "arrow.down.circle") { save(attachment) }
                            .labelStyle(.titleAndIcon)
                        if let saved = savedFiles[attachment.id] {
                            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        }
                        Button("Copy", systemImage: "doc.on.doc") { act(attachment) { AttachmentActions.copy($0) } }
                        ShareLink(item: AttachmentFileItem(attachment: attachment, mailbox: mailbox), preview: SharePreview(attachment.filename))
                    }
                    .disabled(downloads.isRunning(attachment.id))
                }
            }
        }
        .padding(.top, Tokens.Space.s1)
        .quickLookPreview($previewURL, in: previewItems)
        .protectAttachmentPreview(previewURL)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }

    /// Quick Look opens as soon as the clicked file is here. The message's other
    /// files join its list in message order as they arrive, so the arrow keys page
    /// through them. Closing the panel or clicking another file stops the rest.
    private func preview(_ attachment: AttachmentRecord) {
        let request = UUID()
        previewRequest = request
        Task {
            guard let selected = await download(attachment), previewRequest == request else { return }
            var files = [attachment.id: selected]
            previewItems = [selected]
            previewURL = selected
            for item in attachments where files[item.id] == nil {
                guard previewRequest == request, previewURL != nil else { return }
                guard let file = await download(item) else { continue }
                guard previewRequest == request, previewURL != nil else { return }
                files[item.id] = file
                previewItems = attachments.compactMap { files[$0.id] }
            }
        }
    }

    private func save(_ attachment: AttachmentRecord) {
        act(attachment) { file in
            if let saved = try await AttachmentActions.save(file, filename: attachment.filename) { savedFiles[attachment.id] = saved }
        }
    }

    private func act(_ attachment: AttachmentRecord, operation: @escaping @MainActor (URL) async throws -> Void) {
        Task {
            guard let file = await download(attachment) else { return }
            do { try await operation(file) }
            catch { mailbox.notice = MailboxModel.Notice(message: "Couldn't open or save “\(attachment.filename)”. Try again.", isError: true) }
        }
    }

    /// Files that fail to download or copy are skipped, and the notice says how many arrived.
    private func saveAll() {
        isSavingAll = true
        Task {
            defer { isSavingAll = false }
            var files: [URL] = []
            for attachment in attachments {
                if let file = await download(attachment) { files.append(file) }
            }
            // A failed download has already shown why.
            guard !files.isEmpty, let saved = await AttachmentActions.saveAll(files) else { return }
            let total = attachments.count
            mailbox.notice = switch saved {
            case total: MailboxModel.Notice(message: "Saved all \(total) attachments.")
            case 0: MailboxModel.Notice(message: "Couldn't save the attachments. Try another folder.", isError: true)
            default: MailboxModel.Notice(message: "Saved \(saved) of \(total) attachments.", isError: true)
            }
        }
    }

    private func download(_ attachment: AttachmentRecord) async -> URL? {
        let mailbox = mailbox
        return await downloads.value(for: attachment.id) { await mailbox.download(attachment) }
    }
}

/// An attachment as a file for dragging and sharing. The download happens
/// when the receiver asks for the file, so an untouched chip costs nothing.
private struct AttachmentFileItem: Transferable {
    let attachment: AttachmentRecord
    let mailbox: MailboxModel

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            guard let file = await item.mailbox.download(item.attachment) else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(file)
        }
        .suggestedFileName { $0.attachment.filename }
    }
}
