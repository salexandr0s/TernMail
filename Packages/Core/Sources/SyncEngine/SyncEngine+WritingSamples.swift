import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    /// Selects up to 100 distinct SENT messages in Gmail's listing order, then
    /// returns usable excerpts ordered by internalDate. Gmail exposes no explicit
    /// ordering option; this bounded window does not prove global chronological
    /// completeness. It never caches mail, marks it read, or fetches file attachments.
    public func assistantWritingSamples(
        isAuthorized: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> AssistantWritingSamples {
        typealias Limits = AssistantWritingSampleLimits
        var selected: [MessageRef] = []
        var seen = Set<String>()
        var tokens = Set<String>()
        var token: String?
        var failures: [AssistantWritingSampleFailure] = []
        var hasMore = false
        var listingFinished = false
        for _ in 0..<Limits.pages {
            try await writingSamplesCheckAccess(isAuthorized)
            let page: MessageListPage
            do {
                page = try await gmail.listMessages(query: "in:sent", labelIDs: [SystemLabel.sent],
                                                    includeSpamTrash: false, pageToken: token, maxResults: Limits.messages)
                try await writingSamplesCheckAccess(isAuthorized)
            } catch {
                try await writingSamplesCheckAccess(isAuthorized)
                if Self.writingSamplesAccessError(error) { throw error }
                failures.append(.init(reason: .listingUnavailable))
                hasMore = true; listingFinished = true
                break
            }
            let references = page.messages ?? []
            if references.count > Limits.messages { failures.append(.init(reason: .invalidListing)) }
            var processed = 0
            for reference in references.prefix(Limits.messages) {
                processed += 1
                guard !reference.id.isEmpty, !reference.threadId.isEmpty else {
                    failures.append(.init(reason: .invalidListing)); continue
                }
                if seen.insert(reference.id).inserted { selected.append(reference) }
                if selected.count == Limits.messages { break }
            }
            hasMore = page.nextPageToken != nil || processed < references.count
            if selected.count == Limits.messages || page.nextPageToken == nil {
                listingFinished = true; break
            }
            guard let next = page.nextPageToken, !next.isEmpty, next.utf8.count <= 4_096 else {
                failures.append(.init(reason: .invalidListing)); listingFinished = true; break
            }
            guard tokens.insert(next).inserted else {
                failures.append(.init(reason: .repeatedPageToken)); listingFinished = true; break
            }
            token = next
        }
        if !listingFinished { failures.append(.init(reason: .pageLimit)); hasMore = true }

        var inspected = 0
        var samples: [AssistantWritingSample] = []
        var bodyBudget = Limits.totalBodyBytes
        var excerptBudget = Limits.totalSampleBytes
        var truncated = !failures.isEmpty
        for start in stride(from: 0, to: selected.count, by: Limits.batchSize) {
            let batch = Array(selected[start..<min(start + Limits.batchSize, selected.count)])
            try await writingSamplesCheckAccess(isAuthorized)
            let responses: [String: Result<GmailMessage, GmailError>]
            do {
                responses = try await gmail.messages(ids: batch.map(\.id), format: .full, metadataHeaders: [])
                try await writingSamplesCheckAccess(isAuthorized)
            } catch {
                try await writingSamplesCheckAccess(isAuthorized)
                if Self.writingSamplesAccessError(error) { throw error }
                failures += batch.map { .init(messageID: $0.id, reason: .messageUnavailable) }
                truncated = true; continue
            }
            for reference in batch {
                try await writingSamplesCheckAccess(isAuthorized)
                let message: GmailMessage
                do {
                    guard let response = responses[reference.id] else { throw GmailError.missingBatchPart }
                    message = try response.get()
                } catch {
                    if Self.writingSamplesAccessError(error) { throw error }
                    failures.append(.init(messageID: reference.id, reason: .messageUnavailable))
                    truncated = true; continue
                }
                guard message.id == reference.id, message.threadId == reference.threadId,
                      message.labelIds?.contains(SystemLabel.sent) == true else {
                    failures.append(.init(messageID: reference.id, reason: .invalidMessage))
                    truncated = true; continue
                }
                inspected += 1
                // Still inspect the selected full responses when excerpts are full,
                // but do not download additional body parts or process their text.
                guard excerptBudget > 0 else {
                    failures.append(.init(messageID: message.id, reason: .excerptLimit))
                    truncated = true; continue
                }
                guard let inlineBytes = Self.writingSampleInlineBytes(message.payload),
                      inlineBytes <= min(Limits.bodyBytesPerMessage, bodyBudget) else {
                    failures.append(.init(messageID: message.id, reason: .bodyTooLarge))
                    truncated = true; continue
                }
                bodyBudget -= inlineBytes
                var messageBudget = Limits.bodyBytesPerMessage - inlineBytes
                var parts: [String: Data] = [:]
                let required = MIMEParts.requiredAttachmentIDs(of: message).sorted()
                var incomplete = required.count > Limits.bodyPartsPerMessage
                if incomplete { failures.append(.init(messageID: message.id, reason: .bodyPartsLimited)) }
                for id in required.prefix(Limits.bodyPartsPerMessage) {
                    try await writingSamplesCheckAccess(isAuthorized)
                    guard let declared = Self.writingSamplePartSize(id, in: message.payload), declared >= 0 else {
                        failures.append(.init(messageID: message.id, reason: .bodySizeUnknown)); incomplete = true; continue
                    }
                    guard declared <= min(messageBudget, bodyBudget), messageBudget > 0, bodyBudget > 0 else {
                        failures.append(.init(messageID: message.id, reason: .bodyTooLarge)); incomplete = true; continue
                    }
                    do {
                        let data = try await gmail.attachment(messageID: message.id, attachmentID: id)
                        try await writingSamplesCheckAccess(isAuthorized)
                        guard data.count <= min(messageBudget, bodyBudget) else {
                            bodyBudget = max(0, bodyBudget - data.count)
                            messageBudget = 0
                            failures.append(.init(messageID: message.id, reason: .bodyTooLarge)); incomplete = true; continue
                        }
                        messageBudget -= data.count; bodyBudget -= data.count
                        parts[id] = data
                    } catch {
                        try await writingSamplesCheckAccess(isAuthorized)
                        if Self.writingSamplesAccessError(error) { throw error }
                        failures.append(.init(messageID: message.id, reason: .bodyUnavailable)); incomplete = true
                    }
                }
                let body = MIMEParts.body(of: message, attachments: parts)
                let cleaned = WritingSampleText.extract(html: body.html, plainText: body.plainText,
                                                        maximumBytes: min(Limits.bytesPerSample, excerptBudget))
                try await writingSamplesCheckAccess(isAuthorized)
                truncated = truncated || incomplete || cleaned.truncated
                guard cleaned.isUsable else { continue }
                excerptBudget -= cleaned.text.utf8.count
                samples.append(.init(messageID: message.id, date: message.date, text: cleaned.text,
                                     truncated: incomplete || cleaned.truncated))
            }
        }
        try await writingSamplesCheckAccess(isAuthorized)
        samples.sort {
            let first = $0.date ?? .distantPast, second = $1.date ?? .distantPast
            return first == second ? $0.messageID < $1.messageID : first > second
        }
        return AssistantWritingSamples(accountID: accountID, requestedCount: Limits.messages,
                                       selectedCount: selected.count, inspectedCount: inspected, samples: samples,
                                       skippedCount: inspected - samples.count, failures: failures,
                                       truncated: truncated, hasMoreSentMail: hasMore)
    }

    private func writingSamplesCheckAccess(_ isAuthorized: @Sendable () async -> Bool) async throws {
        try writingSamplesCheckLifecycle()
        let authorized = await isAuthorized()
        try writingSamplesCheckLifecycle()
        guard authorized else { throw AssistantMailError.accessChanged }
    }

    private func writingSamplesCheckLifecycle() throws {
        if isStopped || stopRequested.withLock({ $0 }) || Task.isCancelled { throw CancellationError() }
    }

    private static func writingSamplesAccessError(_ error: any Error) -> Bool {
        if error is CancellationError || (error as? AssistantMailError) == .accessChanged { return true }
        guard let gmail = error as? GmailError else { return false }
        return gmail == .unauthorized || gmail.isMissingScope
    }

    /// Check encoded sizes and tree bounds before MIMEParts decodes any inline
    /// content, including an inline image or a malformed nontext part.
    private static func writingSampleInlineBytes(_ payload: MessagePart?) -> Int? {
        guard let payload else { return 0 }
        var stack = [(payload, 0)]
        var nodes = 0
        var bytes = 0
        while let (part, depth) = stack.popLast() {
            nodes += 1
            guard nodes <= 128, depth <= 16 else { return nil }
            if let data = part.body?.data {
                guard data.utf8.count <= AssistantWritingSampleLimits.bodyBytesPerMessage * 2 else { return nil }
                bytes += (data.utf8.count / 4) * 3 + 3
                guard bytes <= AssistantWritingSampleLimits.bodyBytesPerMessage else { return nil }
            }
            let children = part.parts ?? []
            guard children.count <= 128 - nodes - stack.count else { return nil }
            stack += children.map { ($0, depth + 1) }
        }
        return bytes
    }

    private static func writingSamplePartSize(_ id: String, in part: MessagePart?) -> Int? {
        guard let part else { return nil }
        if part.body?.attachmentId == id { return part.body?.size }
        return (part.parts ?? []).compactMap { writingSamplePartSize(id, in: $0) }.max()
    }
}
