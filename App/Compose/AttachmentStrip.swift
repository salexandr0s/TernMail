import AppKit
import MailStore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The files attached to a draft, in a row under the message. Clicking one,
/// or pressing Space on it, opens it in Quick Look, where the arrow keys page
/// through the draft's other files. Dragging one out copies the file.
struct AttachmentStrip: View {
    let attachments: [OutgoingAttachment]
    /// Files that failed to attach or to be removed, marked as failed in the row.
    let failed: [ComposeModel.FailedAttachment]
    let isEditable: Bool
    /// A copy of the file under its own name, or nil when it can't be read.
    let fileURL: @MainActor (OutgoingAttachment) async -> URL?
    let retry: (ComposeModel.FailedAttachment) -> Void
    /// Takes a failed file off the list, which keeps one that couldn't be removed.
    let dismissFailure: (ComposeModel.FailedAttachment) -> Void
    let remove: (OutgoingAttachment) -> Void
    @State private var previewURL: URL?
    @State private var previewItems: [URL] = []
    /// The files Quick Look pages through, so removing one closes it.
    @State private var previewIDs: Set<Int64> = []
    @FocusState private var focusedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    ForEach(attachments) { attachment in
                        if let failure = failed.first(where: { $0.removedID == attachment.id }) {
                            failedChip(failure)
                        } else {
                            chip(attachment)
                        }
                    }
                    ForEach(failed.filter { !$0.isRemoval }) { failure in
                        failedChip(failure)
                    }
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
            }
            .scrollIndicators(.automatic)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Tokens.Surface.muted)
        .quickLookPreview($previewURL, in: previewItems)
        .onChange(of: attachments.compactMap(\.id)) { _, ids in
            if !previewIDs.isSubset(of: ids) { previewURL = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }

    private func chip(_ attachment: OutgoingAttachment) -> some View {
        AttachmentChip(filename: attachment.filename, size: attachment.size, open: { preview(attachment) }) {
            if isEditable {
                Button {
                    remove(attachment)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                }
                .buttonStyle(.borderless)
                .help("Remove \(attachment.filename)")
                .accessibilityLabel("Remove \(attachment.filename)")
            }
        }
        .focusable()
        .focused($focusedID, equals: attachment.id)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .onKeyPress(.space) {
            if previewURL == nil { preview(attachment) } else { previewURL = nil }
            return .handled
        }
        .draggable(OutgoingAttachmentFileItem(filename: attachment.filename) { await fileURL(attachment) })
        .contextMenu {
            Button("Quick Look", systemImage: "eye") { preview(attachment) }
            Button("Show in Finder", systemImage: "folder") { reveal(attachment) }
            if isEditable {
                Divider()
                Button("Remove", systemImage: "xmark", role: .destructive) { remove(attachment) }
            }
        }
    }

    /// A file that failed to attach or to be removed, with Retry, and Remove
    /// for one that wasn't attached or Keep for one still attached.
    private func failedChip(_ failure: ComposeModel.FailedAttachment) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Status.warning)
                .frame(width: Tokens.Control.avatar, height: Tokens.Control.avatar)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text(failure.filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(failure.isRemoval ? "Couldn't remove" : "Couldn't attach")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isEditable {
                Button("Retry") { retry(failure) }
                Button(failure.isRemoval ? "Keep" : "Remove") { dismissFailure(failure) }
            }
        }
        .controlSize(.small)
        .padding(Tokens.Space.s1)
        .frame(maxWidth: Tokens.Layout.attachmentWidth, alignment: .leading)
        .ternSurface()
        .help(failure.reason)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(failure.filename), \(failure.isRemoval ? "couldn't remove" : "couldn't attach")")
    }

    /// Quick Look pages through the draft's files, so each gets its copy first.
    private func preview(_ attachment: OutgoingAttachment) {
        focusedID = attachment.id
        Task {
            var files: [URL] = []
            var ids: Set<Int64> = []
            var selected: URL?
            for item in attachments {
                guard let file = await fileURL(item) else { continue }
                files.append(file)
                if let id = item.id { ids.insert(id) }
                if item.id == attachment.id { selected = file }
            }
            guard let selected else { return }
            previewItems = files
            previewIDs = ids
            previewURL = selected
        }
    }

    private func reveal(_ attachment: OutgoingAttachment) {
        Task {
            guard let url = await fileURL(attachment) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// An attachment as a file for dragging out. The copy is written when the
/// receiver asks for the file.
private struct OutgoingAttachmentFileItem: Transferable {
    let filename: String
    let file: @MainActor () async -> URL?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            guard let url = await item.file() else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.filename }
    }
}
