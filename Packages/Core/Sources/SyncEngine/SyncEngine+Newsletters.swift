import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    public func newsletterSnapshot() async throws -> NewsletterSnapshot {
        try checkNewsletterAccess()
        let accountID = accountID, ownerID = newsletterOwnerID, date = now()
        let abandoned = abandonedNewsletterRequests
        let snapshot = try await write { tx in
            try tx.recoverNewsletterRequests(accountID: accountID, ownerID: ownerID,
                abandonedRequestIDs: abandoned, now: date)
            return try tx.newsletters(accountID: accountID)
        }
        abandonedNewsletterRequests.subtract(abandoned)
        return snapshot
    }

    /// Reads one bounded page of received-mail metadata. No bodies are fetched,
    /// mail is never marked read, and the normal sync cursor is unchanged.
    @discardableResult
    public func loadNewsletterPage(restart: Bool = false) async throws -> NewsletterSnapshot {
        try checkNewsletterAccess()
        let accountID = accountID
        let pageSize = 500
        let state = try await write { try $0.beginNewsletterScan(accountID: accountID, restart: restart) }
        if state.isComplete { return try await newsletterSnapshot() }
        do {
            let page = try await gmail.listMessages(query: "-in:sent -in:drafts -in:spam -in:trash -in:chats",
                labelIDs: [], includeSpamTrash: false, pageToken: state.nextPageToken, maxResults: pageSize)
            try checkNewsletterAccess()
            let references = page.messages ?? []
            guard references.count <= pageSize else { throw GmailError.decoding("Newsletter page size") }
            if let token = page.nextPageToken {
                guard !token.isEmpty, token.utf8.count <= 4_096, token != state.nextPageToken else {
                    throw NewsletterStoreError.repeatedPageToken
                }
            }
            var identities: [String: String] = [:]
            for reference in references {
                guard Self.validNewsletterID(reference.id), Self.validNewsletterID(reference.threadId),
                      identities[reference.id] == nil || identities[reference.id] == reference.threadId else {
                    throw GmailError.decoding("Newsletter message identity")
                }
                identities[reference.id] = reference.threadId
            }
            let ids = identities.keys.sorted()
            let headers = Array(Set(Self.metadataHeaders + NewsletterHeaders.metadataHeaders)).sorted()
            var messages: [NewsletterMessage] = []
            for offset in stride(from: 0, to: ids.count, by: 25) {
                try checkNewsletterAccess()
                let batch = Array(ids[offset..<min(offset + 25, ids.count)])
                let responses = try await gmail.messages(ids: batch, format: .metadata, metadataHeaders: headers)
                try checkNewsletterAccess()
                for id in batch {
                    guard let response = responses[id] else { throw GmailError.missingBatchPart }
                    let message: GmailMessage
                    do { message = try response.get() }
                    catch GmailError.notFound { continue }
                    guard message.id == id, message.threadId == identities[id], let labels = message.labelIds,
                          labels.count <= 1_000,
                          (message.payload?.headers ?? []).reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 65_536
                    else { throw GmailError.decoding("Newsletter metadata") }
                    let eligible = Set(labels).isDisjoint(with: [SystemLabel.sent, SystemLabel.draft,
                        SystemLabel.spam, SystemLabel.trash, "CHAT"])
                    let senders = EmailAddress.parseList(message.header("From") ?? "").filter(\.isValid)
                    let sender = senders.count == 1 ? senders[0] : nil
                    let options = eligible && sender != nil ? NewsletterHeaders.parse(message) : nil
                    messages.append(.init(accountID: accountID, generation: state.generation,
                        messageID: id, threadID: message.threadId, date: message.date ?? .distantPast,
                        subject: String((message.header("Subject") ?? "").prefix(1_024)), sender: sender, options: options))
                }
            }
            try checkNewsletterAccess()
            let updates = messages, deleted = deletedMessageIDs, date = now()
            return try await write { tx in
                let live = deleted.withLock { gone in updates.filter { !gone.contains($0.messageID) } }
                return try tx.commitNewsletterPage(state, messages: live, nextPageToken: page.nextPageToken, now: date)
            }
        } catch {
            try checkNewsletterAccess()
            let expired: Bool
            if case GmailError.http(status: 400, _) = error, state.nextPageToken != nil { expired = true }
            else if error is NewsletterStoreError { expired = true }
            else { expired = false }
            try await write { try $0.failNewsletterScan(state, paginationExpired: expired) }
            throw error
        }
    }

    func checkNewsletterAccess() throws {
        if isStopped || stopRequested.withLock({ $0 }) || Task.isCancelled { throw CancellationError() }
    }

    private static func validNewsletterID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
}
