import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    /// Reads Gmail's recent listing window across received and sent mail. Gmail
    /// has no explicit sort option; internalDate orders the selected window.
    /// Ordinary message metadata joins the cache for exact-message label overlays.
    /// This read never changes Gmail, downloads bodies, or advances a sync cursor.
    public func organizationSamples(
        isAuthorized: @escaping @Sendable () async -> Bool = { true },
        progress: @escaping @Sendable (MailOrganizationSamplingProgress) async -> Void = { _ in }
    ) async throws -> MailOrganizationSamples {
        typealias Limits = MailOrganizationSampleLimits
        try await organizationReport(.init(stage: .labels), progress: progress, isAuthorized: isAuthorized)
        let labels = try await gmail.labels()
        try await organizationReport(.init(stage: .listing), progress: progress, isAuthorized: isAuthorized)
        var selected: [MessageRef] = []
        var seen = Set<String>()
        var tokens = Set<String>()
        var token: String?
        var partial = false
        var finished = false
        for _ in 0..<Limits.pages {
            try await organizationCheckAccess(isAuthorized)
            let page: MessageListPage
            do {
                page = try await gmail.listMessages(query: "-in:drafts -in:chats -in:spam -in:trash",
                    labelIDs: [], includeSpamTrash: false, pageToken: token, maxResults: Limits.messages)
                try await organizationCheckAccess(isAuthorized)
            } catch {
                try await organizationCheckAccess(isAuthorized)
                if Self.organizationAccessError(error) || selected.isEmpty { throw error }
                partial = true
                finished = true
                break
            }
            let references = page.messages ?? []
            if references.count > Limits.messages { partial = true }
            for reference in references.prefix(Limits.messages) {
                guard Self.organizationValidID(reference.id), Self.organizationValidID(reference.threadId) else {
                    partial = true
                    continue
                }
                if seen.insert(reference.id).inserted { selected.append(reference) }
                if selected.count == Limits.messages { break }
            }
            try await organizationReport(.init(stage: .listing, selectedCount: selected.count),
                                         progress: progress, isAuthorized: isAuthorized)
            if selected.count == Limits.messages || page.nextPageToken == nil {
                finished = true
                break
            }
            guard let next = page.nextPageToken, !next.isEmpty, next.utf8.count <= 4_096,
                  tokens.insert(next).inserted else {
                partial = true
                finished = true
                break
            }
            token = next
        }
        if !finished { partial = true }

        var samples: [MailOrganizationSample] = []
        var updates: [CacheTransaction.MessageUpdate] = []
        var processed = 0
        try await organizationReport(.init(stage: .reading, selectedCount: selected.count),
                                     progress: progress, isAuthorized: isAuthorized)
        for start in stride(from: 0, to: selected.count, by: Limits.batchSize) {
            try await organizationCheckAccess(isAuthorized)
            let batch = Array(selected[start..<min(start + Limits.batchSize, selected.count)])
            let responses: [String: Result<GmailMessage, GmailError>]
            do {
                responses = try await gmail.messages(ids: batch.map(\.id), format: .metadata,
                                                     metadataHeaders: Self.metadataHeaders)
                try await organizationCheckAccess(isAuthorized)
            } catch {
                try await organizationCheckAccess(isAuthorized)
                if Self.organizationAccessError(error) { throw error }
                partial = true
                processed += batch.count
                try await organizationReport(.init(stage: .reading, processedCount: processed, selectedCount: selected.count),
                                             progress: progress, isAuthorized: isAuthorized)
                continue
            }
            for reference in batch {
                guard let response = responses[reference.id] else { partial = true; continue }
                let message: GmailMessage
                do { message = try response.get() }
                catch {
                    if Self.organizationAccessError(error) { throw error }
                    partial = true
                    continue
                }
                guard message.id == reference.id, message.threadId == reference.threadId,
                      let labelIDs = message.labelIds,
                      !labelIDs.contains(where: [SystemLabel.draft, SystemLabel.spam, SystemLabel.trash, "CHAT"].contains),
                      labelIDs.count <= 1_000,
                      (message.payload?.headers ?? []).reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 65_536,
                      (message.snippet?.utf8.count ?? 0) <= 16_384,
                      let update = try? Mapping.message(message, accountID: accountID) else {
                    partial = true
                    continue
                }
                let senders = EmailAddress.parseList(message.header("From") ?? "").filter(\.isValid)
                let recipients = EmailAddress.parseList((message.header("To") ?? "") + "," + (message.header("Cc") ?? ""))
                    .filter(\.isValid).prefix(20).map(\.normalized)
                let subject = Self.organizationBound(message.header("Subject") ?? "", bytes: Limits.subjectBytes)
                let snippet = Self.organizationBound(HTMLEntities.decode(message.snippet ?? ""), bytes: Limits.snippetBytes)
                samples.append(.init(messageID: message.id, threadID: message.threadId,
                    sender: senders.count == 1 ? senders[0].normalized : "", recipients: recipients,
                    subject: subject, snippet: snippet, date: message.date,
                    isSent: labelIDs.contains(SystemLabel.sent), labelIDs: labelIDs))
                updates.append(update)
            }
            processed += batch.count
            try await organizationReport(.init(stage: .reading, processedCount: processed, selectedCount: selected.count),
                                         progress: progress, isAuthorized: isAuthorized)
        }
        try await organizationCheckAccess(isAuthorized)
        let accountID = accountID
        let metadata = updates
        let deleted = deletedMessageIDs
        let expires = now().addingTimeInterval(CacheHolds.searchLifetime)
        if !metadata.isEmpty {
            let retained = try await write { tx in
                let live = deleted.withLock { gone in metadata.filter { !gone.contains($0.record.id) } }
                let threads = try tx.upsertMessages(live)
                try tx.holdSearchResults(Set(live.map(\.record.threadID)), until: expires, accountID: accountID)
                try tx.rebuildThreads(threads, accountID: accountID)
                return Set(live.map(\.record.id))
            }
            samples.removeAll { !retained.contains($0.messageID) }
        }
        try await organizationCheckAccess(isAuthorized)
        let inspected = samples
        samples = deleted.withLock { gone in inspected.filter { !gone.contains($0.messageID) } }
        samples.sort {
            let first = $0.date ?? .distantPast, second = $1.date ?? .distantPast
            return first == second ? $0.messageID < $1.messageID : first > second
        }
        return .init(accountID: accountID, messages: samples, existingLabels: labels,
                     selectedCount: selected.count, unavailableCount: selected.count - samples.count,
                     isPartial: partial || samples.count < selected.count)
    }

    private func organizationReport(
        _ value: MailOrganizationSamplingProgress,
        progress: @Sendable (MailOrganizationSamplingProgress) async -> Void,
        isAuthorized: @Sendable () async -> Bool
    ) async throws {
        try await organizationCheckAccess(isAuthorized)
        await progress(value)
        // Reporting can suspend across cancellation or a permission change.
        try await organizationCheckAccess(isAuthorized)
    }

    private func organizationCheckAccess(_ isAuthorized: @Sendable () async -> Bool) async throws {
        try organizationCheckLifecycle()
        let allowed = await isAuthorized()
        try organizationCheckLifecycle()
        guard allowed else { throw AssistantMailError.accessChanged }
    }

    private func organizationCheckLifecycle() throws {
        if isStopped || stopRequested.withLock({ $0 }) || Task.isCancelled { throw CancellationError() }
    }

    private static func organizationAccessError(_ error: any Error) -> Bool {
        if error is CancellationError || (error as? AssistantMailError) == .accessChanged { return true }
        guard let gmail = error as? GmailError else { return false }
        return gmail == .unauthorized || gmail.isMissingScope
    }

    private static func organizationValidID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func organizationBound(_ text: String, bytes limit: Int) -> String {
        var bytes = Array(text.utf8.prefix(limit))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
}
