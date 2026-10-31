import MailStore
import MessageContent

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
        let isAllowed = loadAssistantMailSource(source) { mailbox in
            mailbox.selectedMailbox = .account(source.accountID, SystemLabel.allMail)
            mailbox.selectedThreadIDs = [ThreadKey(accountID: source.accountID, threadID: source.threadID)]
        }
        if isAllowed { destination = .mail }
    }

    /// Loads a mail source the same way, then hands its link to `open`, which
    /// shows it in a conversation window.
    func openAssistantSourceInNewWindow(_ source: AssistantSource, open: @escaping @MainActor (MailLink) -> Void) {
        guard !source.isCalendar else { return }
        assistantNavigationTask?.cancel()
        loadAssistantMailSource(source) { _ in
            open(MailLink(accountID: source.accountID, threadID: source.threadID))
        }
    }

    /// Fetches a conversation the assistant may read, then runs `show`. Returns
    /// false when its account is off limits to the assistant.
    @discardableResult
    private func loadAssistantMailSource(_ source: AssistantSource,
                                         then show: @escaping @MainActor (MailboxModel) -> Void) -> Bool {
        guard assistant.enabledAccountIDs.contains(source.accountID),
              !accountsNeedingSignIn.contains(source.accountID),
              let mailbox, let owner = mailbox.account(id: source.accountID) else { return false }
        assistantNavigationTask = Task { [weak self] in
            do {
                try await owner.engine.assistantLoadSource(source.threadID)
                guard let self, !Task.isCancelled, self.mailbox === mailbox,
                      self.assistant.enabledAccountIDs.contains(source.accountID),
                      !self.accountsNeedingSignIn.contains(source.accountID),
                      mailbox.account(id: source.accountID) === owner else { return }
                show(mailbox)
            } catch {
                guard let self, !Task.isCancelled, self.mailbox === mailbox else { return }
                mailbox.notice = MailboxModel.Notice(message: "Couldn't open this source. Try again.", isError: true)
            }
        }
        return true
    }
}
