import MailStore

extension AppModel {
    /// Source buttons carry validated identities rather than model-generated URLs.
    func openAssistantSource(_ source: AssistantSource) {
        assistantNavigationTask?.cancel()
        if case .calendar(let calendarID, let eventID) = source.target {
            guard calendar.assistantScope.allows(.init(accountID: source.accountID, calendarID: calendarID), details: true) else { return }
            assistantNavigationTask = Task {
                await calendar.openEvent(accountID: source.accountID, calendarID: calendarID, eventID: eventID)
            }
            return
        }
        guard assistant.enabledAccountIDs.contains(source.accountID),
              !accountsNeedingSignIn.contains(source.accountID),
              let mailbox, let owner = mailbox.account(id: source.accountID) else { return }
        destination = .mail
        assistantNavigationTask = Task { [weak self] in
            do {
                try await owner.engine.assistantLoadSource(source.threadID)
                guard let self, !Task.isCancelled, self.mailbox === mailbox,
                      self.assistant.enabledAccountIDs.contains(source.accountID),
                      !self.accountsNeedingSignIn.contains(source.accountID),
                      mailbox.account(id: source.accountID) === owner else { return }
                mailbox.selectedMailbox = .account(source.accountID, SystemLabel.allMail)
                mailbox.selectedThreadIDs = [ThreadKey(accountID: source.accountID, threadID: source.threadID)]
            } catch {
                guard let self, !Task.isCancelled, self.mailbox === mailbox else { return }
                mailbox.notice = MailboxModel.Notice(message: "Couldn't open this source. Try again.", isError: true)
            }
        }
    }
}
