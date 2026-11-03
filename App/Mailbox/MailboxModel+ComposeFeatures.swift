import AppKit
import MailStore
import MessageContent

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
            let draft = try await owner.engine.startReply(kind, to: messageID)
            try await prepareComposeDefaults(draftID: draft.id, owner: owner)
            if let selection { try await owner.engine.replaceSelectedQuote(localDraftID: draft.id, text: selection) }
            return draft.id
        } catch { notice = Notice(message: "Couldn't start this reply.", isError: true); return nil }
    }

    func startForwardingAttachment(messageID: String, accountID: String) async -> String? {
        guard let owner = account(id: accountID) else { return nil }
        do {
            let raw = try await owner.engine.rawMessage(id: messageID)
            let draft = try await owner.engine.startMessage()
            let record = try await cache.read { try $0.message(id: messageID, accountID: accountID) }
            var content = draft.content; content.subject = "Fwd: " + (record?.subject ?? "Message")
            _ = try await owner.engine.updateDraft(draft.id, content: content)
            _ = try await owner.engine.attachData(raw, filename: "Forwarded Message.eml", mimeType: "message/rfc822", to: draft.id)
            try await prepareComposeDefaults(draftID: draft.id, owner: owner)
            return draft.id
        } catch { notice = Notice(message: "Couldn't forward this message as an attachment.", isError: true); return nil }
    }

    func startSendAgain(messageID: String, accountID: String) async -> String? {
        guard let owner = account(id: accountID) else { return nil }
        do {
            let opened = try await owner.engine.startAgain(messageID: messageID)
            if opened.droppedFormatting { notice = Notice(message: "This copy keeps supported text formatting. Review it before sending.") }
            return opened.draft.id
        } catch { notice = Notice(message: "Couldn't copy this sent message.", isError: true); return nil }
    }

    private func prepareComposeDefaults(draftID: String, owner: AccountMailbox) async throws {
        guard let draft = try await cache.read({ try $0.localDraft(id: draftID) }) else { return }
        let identities = try await accountStore?.identities(accountID: owner.account.id) ?? []
        let account = try await accountStore?.accounts().first { $0.id == owner.account.id } ?? owner.account
        let original: MessageRecord?
        if let source = draft.sourceMessageID { original = try await cache.read { try $0.message(id: source, accountID: account.id) } }
        else { original = nil }
        guard let sender = ComposeSender.preferred(in: ComposeSender.choices(account: account, identities: identities), original: original, kind: draft.kind) else { return }
        var content = draft.content
        content.fromAddress = sender.address; content.composeFont = ComposePreferences.font
        content.signatureHTML = sender.signature(for: draft.kind)
        if let signature = try await accountStore?.composeSignature(accountID: account.id, address: sender.address, kind: draft.kind) {
            content.signatureHTML = signature.html
            content.signatureAboveQuote = signature.aboveQuote
            content.signatureSeparator = signature.separator
        }
        _ = try await owner.engine.updateDraft(draft.id, content: content)
    }
}
