import Foundation
import GmailAPI
import MailStore
import MailOrganization
import MessageContent

extension SyncEngine {
    static let organizationMetadataHeaders = metadataHeaders + ["List-Id", "List-Unsubscribe", "Auto-Submitted"]

    /// Reads Gmail's recent listing window across received and sent mail. Gmail
    /// has no explicit sort option; internalDate orders the selected window.
    /// Ordinary message metadata joins the cache for exact-message label overlays.
    /// This read never changes Gmail, downloads bodies, or advances a sync cursor.
    public func organizationSamples(
        maximumMessages: Int = MailOrganizationSampleLimits.messages,
        isAuthorized: @escaping @Sendable () async -> Bool = { true },
        progress: @escaping @Sendable (MailOrganizationSamplingProgress) async -> Void = { _ in }
    ) async throws -> MailOrganizationSamples {
        typealias Limits = MailOrganizationSampleLimits
        guard (1...OrganizationJobLimits.maximumMessages).contains(maximumMessages) else {
            throw GmailError.invalidRequest("Organization scan size")
        }
        let boundary = Int64(now().timeIntervalSince1970.rounded(.down))
        let query = "-in:drafts -in:chats -in:spam -in:trash before:\(boundary)"
        try await organizationReport(.init(stage: .labels), progress: progress, isAuthorized: isAuthorized)
        let labels = try await gmail.labels()
        try await organizationReport(.init(stage: .rules), progress: progress, isAuthorized: isAuthorized)
        let rules = try await organizationRuleContext(isAuthorized)
        try await organizationReport(.init(stage: .listing), progress: progress, isAuthorized: isAuthorized)
        var selected: [MessageRef] = []
        var seen = Set<String>()
        var tokens = Set<String>()
        var token: String?
        var partial = false
        var hasMore = false
        var finished = false
        let pageSize = min(500, maximumMessages)
        let pageLimit = max(Limits.pages, (maximumMessages + pageSize - 1) / pageSize + Limits.pages)
        for _ in 0..<pageLimit {
            try await organizationCheckAccess(isAuthorized)
            let page: MessageListPage
            do {
                page = try await gmail.listMessages(query: query,
                    labelIDs: [], includeSpamTrash: false, pageToken: token,
                    maxResults: min(pageSize, maximumMessages - selected.count))
                try await organizationCheckAccess(isAuthorized)
            } catch {
                try await organizationCheckAccess(isAuthorized)
                if Self.organizationAccessError(error) || selected.isEmpty { throw error }
                partial = true
                hasMore = true
                finished = true
                break
            }
            let references = page.messages ?? []
            if references.count > 500 { partial = true }
            var consumed = 0
            for reference in references.prefix(500) {
                consumed += 1
                guard Self.organizationValidID(reference.id), Self.organizationValidID(reference.threadId) else {
                    partial = true
                    continue
                }
                if seen.insert(reference.id).inserted { selected.append(reference) }
                if selected.count == maximumMessages { break }
            }
            hasMore = page.nextPageToken != nil || consumed < references.count
            try await organizationReport(.init(stage: .listing, selectedCount: selected.count),
                                         progress: progress, isAuthorized: isAuthorized)
            if selected.count == maximumMessages || page.nextPageToken == nil {
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
        if !finished { partial = true; hasMore = true }

        var samples: [MailOrganizationSample] = []
        var processed = 0
        var sampleBudget = OrganizationSampleBudget()
        var sampleBudgetExceeded = false
        try await organizationReport(.init(stage: .reading, selectedCount: selected.count),
                                     progress: progress, isAuthorized: isAuthorized)
        for start in stride(from: 0, to: selected.count, by: Limits.batchSize) {
            try await organizationCheckAccess(isAuthorized)
            let batch = Array(selected[start..<min(start + Limits.batchSize, selected.count)])
            var batchSamples: [MailOrganizationSample] = []
            var updates: [CacheTransaction.MessageUpdate] = []
            let responses: [String: Result<GmailMessage, GmailError>]
            do {
                responses = try await gmail.messages(ids: batch.map(\.id), format: .metadata,
                                                     metadataHeaders: Self.organizationMetadataHeaders)
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
                // Header bytes are bounded above. Retain all recipients for
                // correspondence checks; the AI request has separate limits.
                let recipients = EmailAddress.parseList((message.header("To") ?? "") + "," + (message.header("Cc") ?? ""))
                    .filter(\.isValid).map(\.normalized).removingDuplicates()
                let subject = Self.organizationBound(message.header("Subject") ?? "", bytes: Limits.subjectBytes)
                let snippet = Self.organizationBound(HTMLEntities.decode(message.snippet ?? ""), bytes: Limits.snippetBytes)
                let hints = Self.organizationHeaderHints(message)
                let sample = MailOrganizationSample(messageID: message.id, threadID: message.threadId,
                    sender: senders.count == 1 ? senders[0].normalized : "", recipients: recipients,
                    subject: subject, snippet: snippet, date: message.date,
                    isSent: labelIDs.contains(SystemLabel.sent), labelIDs: labelIDs,
                    hasMailingListHeaders: hints.mailingList, isAutomated: hints.automated)
                guard sampleBudget.retain(sample) else {
                    partial = true; hasMore = true; sampleBudgetExceeded = true
                    break
                }
                batchSamples.append(sample)
                updates.append(update)
            }
            try await organizationCheckAccess(isAuthorized)
            let retained = try await organizationCacheMetadata(updates)
            samples.append(contentsOf: batchSamples.filter { retained.contains($0.messageID) })
            processed += batch.count
            try await organizationReport(.init(stage: .reading, processedCount: processed, selectedCount: selected.count),
                                         progress: progress, isAuthorized: isAuthorized)
            if sampleBudgetExceeded { break }
        }
        try await organizationCheckAccess(isAuthorized)
        let deleted = deletedMessageIDs
        let inspected = samples
        samples = deleted.withLock { gone in inspected.filter { !gone.contains($0.messageID) } }
        samples.sort {
            let first = $0.date ?? .distantPast, second = $1.date ?? .distantPast
            return first == second ? $0.messageID < $1.messageID : first > second
        }
        return .init(accountID: accountID, messages: samples, existingLabels: labels,
                     selectedCount: selected.count, unavailableCount: selected.count - samples.count,
                     isPartial: partial || samples.count < selected.count,
                     existingFilters: rules.filters, filterContextAvailable: rules.available, hasMore: hasMore)
    }

    private func organizationRuleContext(_ isAuthorized: @Sendable () async -> Bool) async throws
        -> (filters: [GmailFilter], available: Bool) {
        try await organizationCheckAccess(isAuthorized)
        guard let settings else { return ([], false) }
        guard try await organizationSettingsPermission() else { return ([], false) }
        try await organizationCheckAccess(isAuthorized)
        let filters = try await settings.filters()
        try await organizationCheckAccess(isAuthorized)
        guard try await organizationSettingsPermission() else { throw AssistantMailError.accessChanged }
        try await organizationCheckAccess(isAuthorized)
        return (filters, true)
    }

    private func organizationSettingsPermission() async throws -> Bool {
        guard let accounts else { return true }
        guard let account = try await accounts.accounts().first(where: { $0.id == accountID }) else { return false }
        return account.enabledFeatures.contains(AccountFeature.gmailSettings.rawValue)
            && GoogleScopes.isCovered(.gmailSettings, by: account.grantedScopes)
    }

    private func organizationCacheMetadata(_ metadata: [CacheTransaction.MessageUpdate]) async throws -> Set<String> {
        guard !metadata.isEmpty else { return [] }
        let accountID = accountID
        let deleted = deletedMessageIDs
        let expires = now().addingTimeInterval(CacheHolds.searchLifetime)
        return try await write { tx in
            let live = deleted.withLock { gone in metadata.filter { !gone.contains($0.record.id) } }
            let threads = try tx.upsertMessages(live)
            try tx.holdSearchResults(Set(live.map(\.record.threadID)), until: expires, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
            return Set(live.map(\.record.id))
        }
    }

    private static func organizationHeaderHints(_ message: GmailMessage) -> (mailingList: Bool, automated: Bool) {
        let headers = message.payload?.headers ?? []
        let mailingList = headers.contains {
            ["list-id", "list-unsubscribe"].contains($0.name.lowercased())
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let submitted = headers.filter { $0.name.lowercased() == "auto-submitted" }
        let token = submitted.first?.value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let automated = submitted.count == 1 && token.map { ["auto-generated", "auto-replied"].contains($0) } == true
        return (mailingList, automated)
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
