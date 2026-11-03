import Foundation
import MailStore
import MessageContent

extension FollowUpsModel {
    convenience init(app: AppModel?) {
        let isolated = AssistantRuntimeEnvironment.isTestHost || ProcessInfo.processInfo.arguments.contains("--ui-audit")
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
            try await owner.engine.assistantLoadSource(threadID)
            try validate()
            let identities = try await mailbox.accountStore?.identities(accountID: accountID) ?? []
            try validate()
            let snapshot = try await mailbox.cache.read { tx in
                (try tx.messages(threadID: threadID, accountID: accountID),
                 try tx.currentLabels(threadID: threadID, accountID: accountID))
            }
            try validate()
            guard !snapshot.0.isEmpty else { throw FollowUpModelError.invalidSource }
            let own = Set(identities.filter(\.canSend).map { $0.address.lowercased() }).union([owner.account.email.lowercased()])
            return FollowUpThreadSnapshot(accountID: accountID, threadID: threadID, messages: snapshot.0,
                labels: snapshot.1, ownAddresses: own, checkedAt: .now)
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
    }
}
