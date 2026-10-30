import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    /// Converts a copied image attachment to a related part without changing its bytes.
    public func markInlineImage(_ attachment: OutgoingAttachment) async throws -> OutgoingAttachment? {
        guard let id = attachment.id else { return nil }
        let accountID = accountID
        let date = now()
        return try await write { tx in
            guard let draft = try tx.localDraft(id: attachment.localDraftID), draft.accountID == accountID,
                  let stored = try tx.outgoingAttachments(localDraftID: draft.id).first(where: { $0.id == id }), stored.path == attachment.path
            else { throw GmailError.invalidRequest("Outgoing attachment account mismatch") }
            guard ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/tiff", "image/bmp"].contains(stored.mimeType.lowercased()) else { return nil }
            let cid = stored.contentID ?? UUID().uuidString.lowercased() + "@tern.local"
            return try tx.setOutgoingContentID(id: id, contentID: cid, now: date)
        }
    }

    public func outgoingAttachmentData(_ attachment: OutgoingAttachment) async throws -> Data {
        let accountID = accountID
        let stored = try await cache.read { tx -> OutgoingAttachment in
            guard let draft = try tx.localDraft(id: attachment.localDraftID), draft.accountID == accountID,
                  let stored = try tx.outgoingAttachments(localDraftID: draft.id).first(where: { $0.id == attachment.id }),
                  stored.path == attachment.path, !stored.path.split(separator: "/").contains(".."), !stored.path.hasPrefix("/")
            else { throw GmailError.invalidRequest("Outgoing attachment account mismatch") }
            return stored
        }
        if isStopped { throw CancellationError() }
        let url = outgoingDirectory.appending(path: stored.path)
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxMessageSize { throw ComposeError.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= Self.maxMessageSize else { throw ComposeError.tooLarge }
        if isStopped { throw CancellationError() }
        return bytes
    }

    public func replaceSelectedQuote(localDraftID: String, text: String) async throws {
        let accountID = accountID
        let date = now()
        try await write { tx in
            guard try tx.localDraft(id: localDraftID)?.accountID == accountID else { return }
            try tx.replaceDraftQuote(id: localDraftID, text: text, now: date)
        }
    }
}
