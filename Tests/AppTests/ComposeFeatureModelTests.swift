import AppKit
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct ComposeFeatureModelTests {
    @Test func inlineImageAndStylesSurviveEditorNormalization() {
        let reference = InlineImageReference(contentID: "image@tern.local", altText: "Diagram")
        let document = ComposeDocument(blocks: [.init(runs: [.init("Before "), .init("", image: reference), .init(" after", bold: true)])])
        let attributed = AttributedDocument.string(from: document, font: .fixedWidth)
        let storage = NSTextStorage(attributedString: attributed)
        AttributedDocument.normalize(storage, in: NSRange(location: 0, length: storage.length), font: .fixedWidth)
        #expect(AttributedDocument.document(from: storage) == document)
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
    }

    @Test func typedMarkdownWaitsForCompleteDelimitersAndConvertsWithoutLosingText() {
        let old = UserDefaults.standard.object(forKey: ComposePreferences.markdownKey)
        UserDefaults.standard.set(true, forKey: ComposePreferences.markdownKey)
        defer { UserDefaults.standard.set(old, forKey: ComposePreferences.markdownKey) }
        let view = ComposeTextView(usingTextLayoutManager: false)
        view.isRichText = true
        for character in "**bold*" { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(view.string == "**bold*")
        view.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        let document = AttributedDocument.document(from: view.attributedString())
        #expect(document.plainText() == "bold")
        #expect(document.blocks.first?.runs.first?.bold == true)
        for character in " and *soft*" { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let mixed = AttributedDocument.document(from: view.attributedString())
        #expect(mixed.plainText() == "bold and soft")
        #expect(mixed.blocks.first?.runs.first?.bold == true)
        #expect(mixed.blocks.first?.runs.last?.italic == true)
    }

    @Test func mailtoPrefillPersistsBodyRecipientsAndDefaultSenderBeforeOpening() async throws {
        let store = try AccountStore.inMemory()
        let account = AccountRecord(id: "a", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        try await store.save(account)
        let cache = try MailCache.inMemory()
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
                                   outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), snoozeStore: store)
        let request = MailtoRequest(to: [.init(address: "pat@example.com")], cc: [.init(address: "team@example.com")],
                                    subject: "Plan", body: "First\nSecond")
        let id = try #require(await mailbox.startMailto(request))
        let draft = try #require(try await cache.read { try $0.localDraft(id: id) })
        #expect(draft.to == request.to && draft.cc == request.cc && draft.subject == "Plan")
        #expect(draft.body.plainText() == "First\nSecond")
        #expect(draft.fromAddress == account.email)
        await mailbox.stop()
    }

    @Test func manualFromChoiceCancelsAnAutomaticAccountLookup() async throws {
        let old = UserDefaults.standard.object(forKey: ComposePreferences.defaultAccountKey)
        UserDefaults.standard.set("", forKey: ComposePreferences.defaultAccountKey)
        defer { UserDefaults.standard.set(old, forKey: ComposePreferences.defaultAccountKey) }
        let store = try AccountStore.inMemory()
        let first = AccountRecord(id: "a", email: "first@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        let second = AccountRecord(id: "b", email: "second@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        try await store.save(first); try await store.save(second)
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                accountID: second.id, id: "recent", threadID: "t", historyID: 1, date: .now,
                snippet: "", sender: "pat@example.com", recipients: second.email, cc: nil, subject: "", sizeEstimate: 0
            ), labelIDs: [])])
        }
        let mailbox = MailboxModel(account: first, cache: cache, gmail: AuditGmail(),
                                   outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), snoozeStore: store)
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.phase != .open, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let sender = try #require(model.senderChoices.first { $0.account.id == first.id })
        model.content.to = [.init(address: "pat@example.com")]
        model.selectSender(sender)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .open && model.draft?.accountID == first.id)
        model.windowClosed()
        await mailbox.stop()
    }

    @Test func groupCompletionInsertsOnlyACompleteExpansionAndCancelsLateResults() async throws {
        let existing = EmailAddress(address: "existing@example.com")
        var recipients = [existing]
        var writes: [Int] = []
        var complete = false
        var returned = 0
        let group = ContactGroupSuggestion(accountID: "a", resourceName: "contactGroups/team", name: "Team", memberCount: 3)
        let recipient = RecipientField(
            label: "To", addresses: .init(get: { recipients }, set: { writes.append($0.count); recipients = $0 }),
            requestsFocus: .constant(false), isEditable: true,
            expandGroup: { _ in
                try? await Task.sleep(for: .milliseconds(10))
                returned += 1
                return complete ? [existing, .init(address: "one@example.com"), .init(address: "two@example.com")] : nil
            }
        ) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let field = NSTokenField()
        coordinator.field = field
        let rejected = coordinator.tokenField(field, shouldAdd: [RecipientField.GroupToken(group)], at: 0)
        #expect(rejected.isEmpty)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while returned < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recipients == [existing] && writes.isEmpty)
        complete = true
        _ = coordinator.tokenField(field, shouldAdd: [RecipientField.GroupToken(group)], at: 0)
        while recipients.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recipients.map(\.address) == ["existing@example.com", "one@example.com", "two@example.com"])
        #expect(writes == [3])
        let later = ContactGroupSuggestion(accountID: "a", resourceName: "contactGroups/later", name: "Later", memberCount: 3)
        _ = coordinator.tokenField(field, shouldAdd: [RecipientField.GroupToken(later)], at: 0)
        coordinator.cancelRequests()
        while returned < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(writes == [3])
    }

    @Test func selectedQuoteScopeRequiresTheExactAccountThreadAndMessage() {
        let quote = SelectedMailQuote(accountID: "a", threadID: "t", messageID: "m", text: "Selected text")
        #expect(quote.belongsTo(accountID: "a", threadID: "t", messageID: "m"))
        #expect(!quote.belongsTo(accountID: "b", threadID: "t", messageID: "m"))
        #expect(!quote.belongsTo(accountID: "a", threadID: "other", messageID: "m"))
        #expect(!quote.belongsTo(accountID: "a", threadID: "t", messageID: "sibling"))
    }

    @Test func selectedReplyTextReplacesOnlyTheQuoteAndEscapesHTML() async throws {
        let old = UserDefaults.standard.object(forKey: ComposePreferences.quoteKey)
        UserDefaults.standard.set(QuoteSelectionPolicy.always.rawValue, forKey: ComposePreferences.quoteKey)
        defer { UserDefaults.standard.set(old, forKey: ComposePreferences.quoteKey) }
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "a", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        try await cache.write { tx in
            _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                accountID: account.id, id: "source", threadID: "t", historyID: 1, date: .now, snippet: "",
                sender: "pat@example.com", recipients: account.email, cc: nil, subject: "Plan", sizeEstimate: 1,
                rfcMessageID: "<source@example.com>"
            ), labelIDs: [SystemLabel.inbox])])
            try tx.saveBodies([MessageBodyRecord(accountID: account.id, messageID: "source", html: nil, plainText: "Whole message", fetchedAt: .now)])
        }
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
                                   outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let id = try #require(await mailbox.requestReply(.reply, messageID: "source", accountID: account.id, selectedText: "<selected>\nOnly this"))
        let draft = try #require(try await cache.read { try $0.localDraft(id: id) })
        #expect(draft.quotedPlainText == "<selected>\nOnly this")
        #expect(draft.quotedHTML?.contains("&lt;selected&gt;") == true)
        #expect(draft.to.map(\.address) == ["pat@example.com"] && draft.subject == "Re: Plan")
        await mailbox.stop()
    }

    @Test func automaticComposeDefaultFollowsPresentedOrderAndProfile() async throws {
        let old = UserDefaults.standard.object(forKey: ComposePreferences.defaultAccountKey)
        UserDefaults.standard.set("", forKey: ComposePreferences.defaultAccountKey)
        defer { UserDefaults.standard.set(old, forKey: ComposePreferences.defaultAccountKey) }
        let cache = try MailCache.inMemory()
        let first = AccountRecord(id: "a", email: "first@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        let second = AccountRecord(id: "b", email: "second@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: first, cache: cache, gmail: AuditGmail(),
                                   outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        mailbox.applyAccountPresentation(preferences: [.init(accountID: "a", sortOrder: 2), .init(accountID: "b", sortOrder: 1)],
                                         visibleAccountIDs: ["a", "b"])
        #expect(mailbox.composeAccount.account.id == "b")
        mailbox.applyAccountPresentation(preferences: [], visibleAccountIDs: ["a"])
        #expect(mailbox.composeAccount.account.id == "a")
        // A fixed account is an explicit choice and can differ from the current profile.
        UserDefaults.standard.set("b", forKey: ComposePreferences.defaultAccountKey)
        #expect(mailbox.composeAccount.account.id == "b")
        await mailbox.stop()
    }
}
