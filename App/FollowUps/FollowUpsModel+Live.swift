import Foundation
import MailStore
import MessageContent

extension FollowUpsModel {
    convenience init(app: AppModel?) {
        let isolated = app?.launchMode.isIsolated ?? LaunchMode.current.isIsolated
        let scheduler: any FollowUpNotificationScheduling = isolated
            ? SilentFollowUpNotificationScheduler() : NativeFollowUpNotificationScheduler()
        self.init(store: { [weak app] in app?.mailbox?.accountStore }, visibleAccountIDs: { [weak app] in
            app?.accountPreferences?.visibleAccountIDs ?? Set(app?.mailbox?.presentedAccounts.map(\.account.id) ?? [])
        }, canReadAccount: { [weak app] id in
            guard let app, !app.isResettingCache, !app.accountsNeedingSignIn.contains(id),
                  let owner = app.mailbox?.account(id: id) else { return false }
            return owner.syncEnabled
        }, loadThread: { [weak app] accountID, threadID in
            guard let app, let mailbox = app.mailbox, let owner = mailbox.account(id: accountID),
                  owner.syncEnabled, !app.isResettingCache, !app.accountsNeedingSignIn.contains(accountID)
            else { throw FollowUpModelError.unavailable }
            @MainActor func validate() throws {
                try Task.checkCancellation()
                guard app.mailbox === mailbox, mailbox.account(id: accountID) === owner,
                      !app.isResettingCache, !app.accountsNeedingSignIn.contains(accountID), owner.syncEnabled
                else { throw FollowUpModelError.unavailable }
            }
            // This reads all thread metadata through the mail service. It uses
            // no model, message bodies, read-state mutations, or AI permissions.
            let metadata = try await owner.engine.assistantLoadSource(threadID)
            try validate()
            let identities = try await mailbox.accountStore?.identities(accountID: accountID) ?? []
            try validate()
            guard !metadata.isEmpty else { throw FollowUpModelError.invalidSource }
            let effective = try await mailbox.cache.read { try $0.currentLabels(threadID: threadID, accountID: accountID) }
            try validate()
            let excluded: Set<String> = [SystemLabel.draft, SystemLabel.trash, SystemLabel.spam]
            let own = Set(identities.filter(\.canSend).map { $0.address.lowercased() }).union([owner.account.email.lowercased()])
            return FollowUpThreadSnapshot(accountID: accountID, threadID: threadID, messages: metadata.map(\.record),
                labels: Dictionary(uniqueKeysWithValues: metadata.map {
                    ($0.record.id, Set($0.labelIDs).union((effective[$0.record.id] ?? []).intersection(excluded)))
                }), ownAddresses: own, checkedAt: .now)
        }, prepareDraft: { [weak app] record in
            guard let app, let mailbox = app.mailbox, let owner = mailbox.account(id: record.accountID)
            else { throw FollowUpModelError.unavailable }
            let link = MailLink(accountID: record.accountID, threadID: record.threadID, messageID: record.sourceMessageID)
            _ = try await app.mailURLs.resolveConversation(link)
            guard app.mailbox === mailbox, mailbox.account(id: record.accountID) === owner,
                  let id = await mailbox.requestReply(.reply, messageID: record.sourceMessageID,
                    accountID: record.accountID, selectedText: nil) else { throw FollowUpModelError.unavailable }
            guard app.mailbox === mailbox, mailbox.account(id: record.accountID) === owner,
                  let draft = try await mailbox.cache.read({ try $0.localDraft(id: id) }),
                  draft.accountID == record.accountID, draft.threadID == record.threadID,
                  draft.sourceMessageID == record.sourceMessageID else { throw FollowUpModelError.invalidSource }
            var content = draft.content
            let question = record.direction == .waitingFor ? " Could you let me know the current status?" : ""
            content.body = ComposeDocument(plainText: "Following up on \(record.title).\(question)\n\n")
            guard app.mailbox === mailbox, mailbox.account(id: record.accountID) === owner else { throw FollowUpModelError.unavailable }
            _ = try await owner.engine.updateDraft(id, content: content)
            guard app.mailbox === mailbox, mailbox.account(id: record.accountID) === owner else { throw FollowUpModelError.unavailable }
            return id
        }, openMail: { [weak app] record in
            app?.mailURLs.openConversation(MailLink(accountID: record.accountID, threadID: record.threadID,
                messageID: record.sourceMessageID))
        }, scheduler: scheduler)
        canDeliverAutomaticReminders = { [weak app] in app?.automaticFollowUps.settingsReady == true }
    }
}
