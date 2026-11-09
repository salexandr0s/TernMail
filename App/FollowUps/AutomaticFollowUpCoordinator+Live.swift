import Foundation
import MailStore

extension AutomaticFollowUpCoordinator {
    convenience init(app: AppModel?, preferences: FollowUpPreferences, followUps: FollowUpsModel) {
        let isolated = app?.launchMode.isIsolated ?? LaunchMode.current.isIsolated
        self.init(preferences: preferences, followUps: followUps, store: { [weak app] in app?.mailbox?.accountStore },
            accountIDs: { [weak app] in
                guard !isolated, let app, !app.isResettingCache else { return [] }
                return Set(app.mailbox?.accounts.filter { $0.syncEnabled && !app.accountsNeedingSignIn.contains($0.account.id) }
                    .map(\.account.id) ?? [])
            }, cachedCandidates: { [weak app] accountID, since, limit in
                guard !isolated, let app, let mailbox = app.mailbox else { return [] }
                let messages = try await mailbox.cache.read { try $0.automaticFollowUpCandidates(accountID: accountID, since: since, limit: limit) }
                guard app.mailbox === mailbox else { throw CancellationError() }
                return messages.map { ThreadKey(accountID: accountID, threadID: $0.threadID) }
            }, canDraft: { [weak app] accountID in
                guard !isolated, let app, !app.isResettingCache, !app.accountsNeedingSignIn.contains(accountID),
                      app.mailbox?.account(id: accountID)?.syncEnabled == true else { return false }
                return app.assistant.composeAvailabilityMessage(accountID: accountID) == nil
            }, prepareDraft: { [weak app, weak followUps] entry, receipt, authorization in
                guard !isolated, let app, let followUps, let mailbox = app.mailbox,
                      let owner = mailbox.account(id: entry.record.accountID), owner.syncEnabled else { throw AutomaticFollowUpError.unavailable }
                let session = try app.assistant.makeComposeSession(accountID: entry.record.accountID)
                @MainActor func validate() async throws {
                    try Task.checkCancellation()
                    guard app.mailbox === mailbox, mailbox.account(id: entry.record.accountID) === owner,
                          session.isValid(), await authorization.isValid() else { throw CancellationError() }
                }
                @MainActor func hasOtherDraft() async throws -> Bool {
                    try await mailbox.cache.read { tx in
                        try tx.localDrafts(accountID: entry.record.accountID).contains {
                            $0.threadID == entry.record.threadID && $0.id != receipt.draftID && $0.state != .discarding
                        }
                    }
                }
                try await validate()
                guard try await !hasOtherDraft() else { throw AutomaticFollowUpError.existingDraft }
                let service = AutomaticFollowUpDraftService(session: session, isCurrent: {
                    app.mailbox === mailbox && mailbox.account(id: entry.record.accountID) === owner
                        && preferences.automaticRemindersEnabled && preferences.automaticDraftsEnabled
                })
                let proposal = try await service.proposal(for: entry, baselineMessageID: receipt.outgoingMessageID)
                try await validate()
                // Recheck after generation: a reply or a newer outgoing message
                // makes the generated text obsolete before any draft is created.
                let latest = try await followUps.loadThread(entry.record.accountID, entry.record.threadID)
                try await validate()
                guard let candidate = Self.candidate(in: latest), candidate.outgoingMessageID == receipt.outgoingMessageID,
                      !latest.labels.values.contains(where: { $0.contains(SystemLabel.draft) }),
                      try await !hasOtherDraft() else { throw AutomaticFollowUpError.staleConversation }
                _ = try await owner.engine.assistantPrepareDraft(id: receipt.draftID, replyKind: .replyAll,
                    messageID: receipt.outgoingMessageID, expectedThreadID: entry.record.threadID, recipients: [],
                    subject: proposal.subject, text: proposal.body, ownAddresses: latest.ownAddresses,
                    isAuthorized: {
                        guard await authorization.isValid() else { return false }
                        return await MainActor.run {
                            app.mailbox === mailbox && mailbox.account(id: entry.record.accountID) === owner && session.isValid()
                        }
                    })
            })
    }
}
