import Foundation
import MailStore
import MessageContent

extension MeetingPreparationModel {
    convenience init(app: AppModel?, event: CalendarDisplayEvent) {
        let isolated = AssistantRuntimeEnvironment.isTestHost || ProcessInfo.processInfo.arguments.contains("--ui-audit")
        self.init(event: event, followUps: app?.followUps ?? FollowUpsModel(app: nil),
            store: { [weak app] in app?.settingsAccountStore ?? app?.mailbox?.accountStore },
            mailAccountIDs: { [weak app] in
                guard let app, !app.isResettingCache else { return [] }
                let visible = app.accountPreferences?.visibleAccountIDs ?? Set(app.mailbox?.presentedAccounts.map(\.account.id) ?? [])
                return Set(app.mailbox?.accounts.filter {
                    visible.contains($0.account.id) && $0.syncEnabled && !app.accountsNeedingSignIn.contains($0.account.id)
                }.map(\.account.id) ?? [])
            }, access: { [weak app] ids in
                app?.assistant.meetingPreparationAccess(accountIDs: ids) ?? MeetingPreparationAccess(
                    scope: AssistantScopeSnapshot(accountIDs: [], threadIDs: nil, accountInstances: [:], connectionRevision: 0, canUsePlan: false),
                    modelID: "", modelReady: false, permissionRevision: 0, mailboxRuntime: "unavailable")
            }, makeSession: { [weak app] event, ids, generation in
                guard !isolated, let app else { throw MeetingPreparationServiceError.sourceUnavailable }
                return MeetingPreparationSession(service: try app.assistant.makeMeetingPreparationService(event: event, accountIDs: ids,
                    isCurrent: generation.isCurrent))
            }, readEvent: { [weak app] captured in
                guard let app else { throw MeetingPreparationServiceError.sourceUnavailable }
                let updated = try await app.calendar.readEvent(accountID: captured.accountID, calendarID: captured.calendarID, eventID: captured.event.id)
                return captured.replacingEvent(updated)
            }, sourceLinks: { [weak app] captured in
                guard let store = app?.calendar.store else { throw MeetingPreparationServiceError.sourceUnavailable }
                return try await store.sourceLinks(accountID: captured.accountID, calendarID: captured.calendarID, eventID: captured.event.id)
            }, sourceTitle: { [weak app] key in
                guard let mailbox = app?.mailbox else { return nil }
                return try await mailbox.cache.read { try $0.thread(id: key.threadID, accountID: key.accountID)?.subject }
            }, search: { [weak app] query, ids in
                guard let app, let mailbox = app.mailbox else { throw MeetingPreparationServiceError.sourceUnavailable }
                let parsed = SearchQuery(query), date = Date(), zone = TimeZone.current
                let threads = try await mailbox.cache.read { tx in
                    try ids.sorted().flatMap { id in
                        try tx.searchThreads(parsed, accountID: id, timeZone: zone, now: date, limit: 20)
                    }.sorted { $0.lastDate > $1.lastDate }.prefix(20)
                }
                guard app.mailbox === mailbox else { throw CancellationError() }
                return threads.map { thread in
                    MeetingPreparationSourceRow(key: ThreadKey(accountID: thread.accountID, threadID: thread.id),
                        link: MailLink(accountID: thread.accountID, threadID: thread.id), title: thread.subject,
                        reason: "Cached conversation", isExcluded: false, isExplicitlyIncluded: false, unavailableMessage: nil)
                }
            }, threadRevision: { [weak app] key in
                guard let mailbox = app?.mailbox else { return nil }
                var iterator = mailbox.cache.thread(accountID: key.accountID, threadID: key.threadID).makeAsyncIterator()
                let detail = try await iterator.next() ?? nil
                guard app?.mailbox === mailbox else { throw CancellationError() }
                return detail.map(ThreadSummaryModel.revision)
            }, openMail: { [weak app] link in app?.mailURLs.openConversation(link) },
            previewFile: { [weak app] source in
                guard let app, let mailbox = app.mailbox, let owner = mailbox.account(id: source.accountID),
                      let messageID = source.messageID, let partID = source.partID else { throw MeetingPreparationServiceError.sourceUnavailable }
                let link = MailLink(accountID: source.accountID, threadID: source.threadID, messageID: messageID, partID: partID)
                _ = try await app.mailURLs.resolveConversation(link) {
                    app.mailbox === mailbox && mailbox.account(id: source.accountID) === owner
                }
                let attachment = try await mailbox.cache.read { tx in
                    try tx.attachments(messageID: messageID, accountID: source.accountID).first { $0.partID == partID }
                }
                guard app.mailbox === mailbox, mailbox.account(id: source.accountID) === owner, let attachment,
                      let url = await mailbox.download(attachment) else { throw MeetingPreparationServiceError.sourceUnavailable }
                guard app.mailbox === mailbox, mailbox.account(id: source.accountID) === owner else { throw CancellationError() }
                return url
            }, acceptSuggestion: { [weak app] in app?.requestFollowUp($0) })
    }
}
