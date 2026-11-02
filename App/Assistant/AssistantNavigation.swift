import MailStore
import MessageContent

extension AppModel {
    /// Source buttons carry validated identities rather than model-generated URLs.
    func openAssistantSource(_ source: AssistantSource) {
        assistantNavigationTask?.cancel()
        if case .calendar(let calendarID, let eventID) = source.target {
            assistantNavigationTask = Task {
                await calendar.openAssistantEvent(accountID: source.accountID, calendarID: calendarID, eventID: eventID)
            }
            return
        }
        loadAssistantMailSource(source) { [weak self] link in
            self?.mailURLs.presentResolvedConversation(link)
        }
    }

    func openAssistantSourceInNewWindow(_ source: AssistantSource, open: @escaping @MainActor (MailLink) -> Void) {
        guard !source.isCalendar else { return }
        assistantNavigationTask?.cancel()
        loadAssistantMailSource(source, then: open)
    }

    private func loadAssistantMailSource(_ source: AssistantSource,
                                         then show: @escaping @MainActor (MailLink) -> Void) {
        guard let authorized = assistant.sourceNavigationAuthorization(accountID: source.accountID),
              let mailbox else { return }
        let link = MailLink(accountID: source.accountID, threadID: source.threadID,
                            messageID: source.messageID, partID: source.partID)
        assistantNavigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await mailURLs.resolveConversation(link, isAuthorized: authorized)
                guard !Task.isCancelled, authorized(), self.mailbox === mailbox else { return }
                show(resolved)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, authorized(), self.mailbox === mailbox else { return }
                mailbox.notice = MailboxModel.Notice(message: "Couldn't open this source. Its message or attachment may be unavailable; reconnect the account if needed.", isError: true)
            }
        }
    }
}
