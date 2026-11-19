import AppKit
import MailStore
import MessageContent
import SyncEngine

extension MailboxModel {
    func startMailto(_ request: MailtoRequest, accountID: String? = nil) async -> String? {
        if let accountID, account(id: accountID) == nil { return nil }
        var owner = accountID.flatMap { account(id: $0) } ?? composeAccount
        let candidates = selectedAccounts.isEmpty ? presentedAccounts : selectedAccounts
        if accountID == nil, ComposePreferences.defaultAccountID == nil, candidates.count > 1,
           let first = request.to.first,
           let last = try? await cache.lastCorrespondenceAccount(with: first.address, accountIDs: candidates.map { $0.account.id }),
           let recent = account(id: last) { owner = recent }
        do {
            let draft = try await owner.engine.startMessage()
            var content = draft.content
            content.to = request.to; content.cc = request.cc; content.bcc = request.bcc
            content.subject = request.subject; content.body = ComposeDocument(plainText: request.body)
            _ = try await owner.engine.updateDraft(draft.id, content: content)
            try await prepareComposeDefaults(draftID: draft.id, owner: owner)
            return draft.id
        } catch { notice = Notice(message: "Couldn't open this email link.", isError: true); return nil }
    }

    func startMessage(to recipient: EmailAddress, accountID: String) async -> String? {
        guard let owner = account(id: accountID) else { return nil }
        do {
            let draft = try await owner.engine.startMessage()
            var content = draft.content; content.to = [recipient]
            _ = try await owner.engine.updateDraft(draft.id, content: content)
            try await prepareComposeDefaults(draftID: draft.id, owner: owner)
            return draft.id
        } catch { notice = Notice(message: "Couldn't start this message.", isError: true); return nil }
    }

    func requestReply(_ kind: ReplyKind, messageID: String, accountID: String, selectedText: String?) async -> String? {
        guard let owner = account(id: accountID) else { return nil }
        var selection = kind == .forward ? nil : selectedText
        if let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch ComposePreferences.quoteSelection {
            case .never: selection = nil
            case .always: break
            case .ask:
                let alert = NSAlert()
                alert.messageText = "Quote selected text?"
                alert.informativeText = "Use the selected text in this reply, or quote the entire message."
                alert.addButton(withTitle: "Quote Selection")
                alert.addButton(withTitle: "Quote Entire Message")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: break
                case .alertSecondButtonReturn: selection = nil
                default: return nil
                }
            }
        } else { selection = nil }
        do {
            // A quoted selection replaces the whole quote, so that reply waits
            // for it. Any other opens without waiting for Gmail.
            let draft = if selection == nil {
                try await owner.engine.insertReplyShell(kind, to: messageID)
            } else {
                try await owner.engine.startReply(kind, to: messageID)
            }
            try await prepareComposeDefaults(draftID: draft.id, owner: owner, quoting: selection)
            return draft.id
        } catch { notice = Notice(message: "Couldn't start this reply.", isError: true); return nil }
    }

    func startForwardingAttachment(messageID: String, accountID: String) async -> String? {
        guard let owner = account(id: accountID) else { return nil }
        do {
            // The window opens without waiting for Gmail and gets the message's file when it comes.
            let draft = try await owner.engine.insertForwardAsAttachment(of: messageID)
            try await prepareComposeDefaults(draftID: draft.id, owner: owner)
            return draft.id
        } catch {
            let message = (error as? ComposeError)?.errorDescription ?? "Couldn't forward this message as an attachment."
            notice = Notice(message: message, isError: true)
            return nil
        }
    }

    func startSendAgain(messageID: String, accountID: String) async -> String? {
        guard let owner = account(id: accountID) else { return nil }
        do {
            let opened = try await owner.engine.startAgain(messageID: messageID)
            if opened.droppedFormatting { notice = Notice(message: "This copy keeps supported text formatting. Review it before sending.") }
            return opened.draft.id
        } catch { notice = Notice(message: "Couldn't copy this sent message.", isError: true); return nil }
    }

    /// Fills in what a draft the app just made starts with: the default
    /// sender with its signature, the compose font, and a quoted selection in
    /// place of the whole quote. A reply goes from the address its original
    /// was sent to when that is one of `senders`. None of this counts as an
    /// edit (`SyncEngine.setUpDraft`), so a reply nobody changed is discarded
    /// when its window closes, even a window macOS restored. Returns the
    /// stored draft, or nil when it no longer takes edits or its account is gone.
    func setUpNewDraft(_ draft: LocalDraft, senders: [ComposeSender], original: MessageRecord?,
                       quoting selection: String? = nil) async throws -> LocalDraft? {
        guard let owner = account(id: draft.accountID) else { return nil }
        var content = draft.content
        let choices = senders.filter { $0.account.id == draft.accountID }
        if let sender = ComposeSender.preferred(in: choices, original: original, kind: draft.kind) {
            content.fromAddress = sender.address
            content.composeFont = ComposePreferences.font
            content.signatureHTML = sender.signature(for: draft.kind)
            // The signature Settings pick for this address, or else its Gmail signature.
            if let signature = try? await accountStore?.composeSignature(accountID: draft.accountID, address: sender.address, kind: draft.kind) {
                content.signatureHTML = signature.html
                content.signatureAboveQuote = signature.aboveQuote
                content.signatureSeparator = signature.separator
            }
        }
        return try await owner.engine.setUpDraft(draft.id, content: content, quoting: selection)
    }

    /// Sets up a draft just made, before its window opens (`setUpNewDraft`).
    /// A draft that can't be set up is removed, so none is left without a
    /// window. It never reached Gmail, so removing it makes no Gmail request.
    private func prepareComposeDefaults(draftID: String, owner: AccountMailbox, quoting selection: String? = nil) async throws {
        do {
            guard let draft = try await cache.read({ try $0.localDraft(id: draftID) }) else { return }
            let identities = (try? await accountStore?.identities(accountID: owner.account.id)) ?? []
            let account = (try? await accountStore?.accounts())?.first { $0.id == owner.account.id } ?? owner.account
            var original: MessageRecord?
            if let source = draft.sourceMessageID {
                original = try? await cache.read { try $0.message(id: source, accountID: draft.accountID) }
            }
            _ = try await setUpNewDraft(draft, senders: ComposeSender.choices(account: account, identities: identities),
                                        original: original, quoting: selection)
        } catch {
            _ = try? await owner.engine.discardDraft(draftID, hold: 0)
            throw error
        }
    }
}
