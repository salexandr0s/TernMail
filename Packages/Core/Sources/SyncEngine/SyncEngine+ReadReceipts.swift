import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    /// Persist candidates before the normal sync cursor advances. Full report
    /// downloads run separately, so their failures cannot stall incoming mail.
    func ingestReadReceiptMetadata(_ messages: [GmailMessage]) async throws {
        let accountID = accountID
        let candidates = messages.filter(ReadReceiptParser.isCandidate)
        guard !candidates.isEmpty else { return }
        let deleted = deletedMessageIDs
        try await write { tx in
            for message in candidates where !deleted.withLock({ $0.contains(message.id) }) {
                try tx.queueReadReceipt(messageID: message.id, accountID: accountID)
            }
        }
    }

    /// At most one batch per sync pass; transport failures remain queued for
    /// a later pass, including across app restarts. No metadata fetch recursion.
    func retryPendingReadReceipts() async throws {
        if isStopped || Task.isCancelled { throw CancellationError() }
        let accountID = accountID
        let attemptedAt = now()
        let ids = try await write { try $0.pendingReadReceiptIDs(accountID: accountID, attemptedAt: attemptedAt) }
        guard !ids.isEmpty else { return }
        do {
            let results = try await gmail.messages(ids: ids, format: .full, metadataHeaders: [])
            for id in ids {
                if isStopped || Task.isCancelled { throw CancellationError() }
                if deletedMessageIDs.withLock({ $0.contains(id) }) {
                    try await write { try $0.finishReadReceipt(messageID: id, accountID: accountID) }
                    continue
                }
                guard let result = results[id] else { continue }
                switch result {
                case .success(let message):
                    guard message.id == id else { continue }
                    guard ReadReceiptParser.isCandidate(message) else {
                        try await write { try $0.finishReadReceipt(messageID: id, accountID: accountID) }
                        continue
                    }
                    do { try await ingestReadReceipt(message) }
                    catch is CancellationError { throw CancellationError() }
                    catch GmailError.notFound {
                        try await write { try $0.finishReadReceipt(messageID: id, accountID: accountID) }
                    }
                    catch { continue }
                case .failure(GmailError.notFound):
                    try await write { try $0.finishReadReceipt(messageID: id, accountID: accountID) }
                case .failure: continue
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The ordinary sync has succeeded; retry this optional download
            // on the next pass without altering its cursor or sync status.
            if isStopped || Task.isCancelled { throw CancellationError() }
        }
    }

    /// Also used when a reader has already fetched a full message. Neither path
    /// marks mail read or sends a receipt in response to an incoming request.
    func ingestReadReceipt(_ message: GmailMessage, attachments: [String: Data] = [:]) async throws {
        if isStopped || Task.isCancelled { throw CancellationError() }
        guard !message.id.isEmpty, ReadReceiptParser.isCandidate(message) else { return }
        let accountID = accountID
        let deleted = deletedMessageIDs
        guard !deleted.withLock({ $0.contains(message.id) }) else { return }
        guard let receivedAt = message.date else {
            try await write { try $0.finishReadReceipt(messageID: message.id, accountID: accountID) }
            return
        }
        try await ingestReadReceiptMetadata([message])
        var parts = attachments
        if let id = ReadReceiptParser.requiredAttachmentID(of: message), parts[id] == nil {
            parts[id] = try await gmail.attachment(messageID: message.id, attachmentID: id)
        }
        let receipt = ReadReceiptParser.receipt(in: message, attachments: parts)
        let reporters = message.header("From").map(EmailAddress.parseList) ?? []
        let addresses = [message.header("To"), message.header("Cc")].compactMap { $0 }
            .flatMap(EmailAddress.parseList).filter(\.isValid).map(\.normalized)
        try await write { tx in
            if !deleted.withLock({ $0.contains(message.id) }), let receipt,
               reporters.count == 1, let reporter = reporters.first, reporter.isValid {
                try tx.storeReadReceipt(receipt, accountID: accountID, receiptMessageID: message.id,
                    reporter: reporter.normalized, returnAddresses: addresses, receivedAt: receivedAt)
            }
            try tx.finishReadReceipt(messageID: message.id, accountID: accountID)
        }
    }

    static func importedReadReceiptRequest(_ message: GmailMessage, sender: EmailAddress?) -> Bool {
        guard let sender, sender.isValid,
              let headers = message.payload?.headers?.filter({ $0.name.caseInsensitiveCompare("Disposition-Notification-To") == .orderedSame }),
              headers.count == 1, let value = headers.first?.value,
              !value.contains("\r"), !value.contains("\n") else { return false }
        let addresses = EmailAddress.parseList(value)
        return addresses.count == 1 && addresses.first?.isValid == true && addresses.first?.normalized == sender.normalized
    }
}
