import Foundation
import GmailAPI
import MailStore
import MessageContent
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct MailContextActionTests {
    @Test func contextualTriageUsesMailLabelsInsteadOfTheSelectedMailbox() {
        let trashed = MailContextState(labels: [[SystemLabel.trash]])
        #expect(!trashed.canArchive)
        #expect(!trashed.canTrash)
        #expect(trashed.canMoveToInbox)
        #expect(trashed.permanentDeletionLabel == SystemLabel.trash)
        let spam = MailContextState(labels: [[SystemLabel.spam, SystemLabel.important]])
        #expect(spam.allSpam && spam.allImportant)
        #expect(spam.permanentDeletionLabel == SystemLabel.spam)
        let mixed = MailContextState(labels: [[SystemLabel.inbox], [SystemLabel.trash, SystemLabel.important]])
        #expect(mixed.canArchive && mixed.canTrash && mixed.canMoveToInbox)
        #expect(!mixed.allImportant)
        #expect(mixed.permanentDeletionLabel == nil)
        #expect(MailContextState(labels: []).permanentDeletionLabel == nil)
        #expect(!MailContextState(labels: [[SystemLabel.draft]]).canMoveToInbox)
    }

    @Test func restoreFromSearchChangesOnlyTheClickedMessage() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        try await cache.write { tx in
            _ = try tx.applyLabelChange(messageID: "m1", added: [SystemLabel.trash, SystemLabel.spam],
                                       removed: [SystemLabel.inbox], historyID: 2, accountID: "a")
        }
        mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "other")]
        mailbox.search.update("Notes")
        await mailbox.moveRowsToInbox([.init(accountID: "a", threadID: "t", messageID: "m1")])?.value
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"]?.contains(SystemLabel.inbox) == true)
        #expect(labels["m1"]?.contains(SystemLabel.trash) == false)
        #expect(labels["m1"]?.contains(SystemLabel.spam) == false)
        #expect(labels["m2"] == [SystemLabel.inbox, "Label_a", "Label_b"])
        #expect(try await cache.read { try $0.currentLabels(threadID: "other", accountID: "a")["m3"] } == [SystemLabel.inbox])
    }

    @Test func readerLabelAndMoveCommandsKeepTheirOwnMessageAndAccount() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        var stream = cache.thread(accountID: "a", threadID: "t").makeAsyncIterator()
        let detail = try #require(try await stream.next())
        let message = try #require(detail?.messages.first { $0.id == "m1" })
        mailbox.selectedMailbox = .account("a", "Label_b")
        mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "other")]
        await mailbox.setLabel("Label_c", applied: true, on: message)?.value
        await mailbox.moveMessage(message, to: "Label_c")?.value
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"] == ["Label_a", "Label_b", "Label_c"])
        #expect(labels["m2"] == [SystemLabel.inbox, "Label_a", "Label_b"])
        #expect(mailbox.setLabel(SystemLabel.trash, applied: true, on: message) == nil)
        #expect(mailbox.moveMessage(message, to: "missing") == nil)
        #expect(mailbox.labelEdit == nil && mailbox.moveTargets == nil)
    }

    @Test func movePickerRetainsTheSourceAndExactMessageAfterNavigation() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.selectedMailbox = .account("a", "Label_a")
        let row = MailListRowID(accountID: "a", threadID: "t", messageID: "m1")
        mailbox.showMoveTo(forRows: [row])
        #expect(mailbox.moveSourceLabelID == "Label_a")
        mailbox.selectedMailbox = .account("a", "Label_b")
        #expect(!mailbox.moveChoices.contains { $0.id == "Label_a" })
        #expect(mailbox.moveChoices.contains { $0.id == "Label_b" })
        await mailbox.move(to: "Label_c")?.value
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"] == ["Label_b", "Label_c"])
        #expect(labels["m2"] == [SystemLabel.inbox, "Label_a", "Label_b"])
        #expect(mailbox.moveTargets == nil && mailbox.moveMessageTargets == nil && mailbox.moveSourceLabelID == nil)
    }

    @Test func aMixedConversationKeepsTrashAndSpamActionsAvailable() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let original = try #require(mailbox.listItems.first { $0.id.threadID == "t" })
        let messages = original.messages.enumerated().map { index, entry in
            MessageListEntry(message: entry.message, labels: index == 0 ? [SystemLabel.inbox] : [SystemLabel.trash, SystemLabel.spam])
        }
        let item = MessageListItem(id: original.id, thread: original.thread, messages: messages)
        let state = MailContextState(items: [item])
        #expect(item.labels.contains(SystemLabel.trash))
        #expect(state.canTrash)
        #expect(!state.allSpam)
        #expect(state.permanentDeletionLabel == nil)
    }

    @Test func movePickerRestoresHiddenSearchResultsToTheDestinationLabel() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        try await cache.write { tx in
            _ = try tx.applyLabelChange(messageID: "m1", added: [SystemLabel.trash, SystemLabel.spam],
                                       removed: [SystemLabel.inbox], historyID: 2, accountID: "a")
        }
        mailbox.search.update("Notes")
        mailbox.showMoveTo(forRows: [.init(accountID: "a", threadID: "t", messageID: "m1")])
        #expect(mailbox.moveChoices.contains { $0.id == SystemLabel.inbox })
        await mailbox.move(to: "Label_c")?.value
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"] == ["Label_a", "Label_b", "Label_c"])
        #expect(labels["m2"] == [SystemLabel.inbox, "Label_a", "Label_b"])
    }

    @Test func markAllReadRejectsVirtualAndUnsyncedMailboxes() {
        #expect(MailTriageModel.canMarkAllRead(.account("a", "Label_a")))
        #expect(MailTriageModel.canMarkAllRead(.combined(SystemLabel.inbox)))
        #expect(!MailTriageModel.canMarkAllRead(.combined(MailboxModel.snoozedID)))
        #expect(!MailTriageModel.canMarkAllRead(.combined(MailboxModel.outboxID)))
        #expect(!MailTriageModel.canMarkAllRead(.combined(MailNavigationModel.searchPrefix + "saved")))
        #expect(!MailTriageModel.canMarkAllRead(.account("a", LabelRules.temporaryPrefix + "pending")))
    }

    @Test func deletionReviewUsesTheClickedRowsAndMailboxWithoutChangingSearchOrSelection() async throws {
        let (mailbox, cache) = try await fixture(gmail: ContextTriageService())
        defer { Task { await mailbox.stop() } }
        mailbox.search.update("Notes")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !mailbox.search.hasLocalAnswer || !mailbox.isListPresentationReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(mailbox.search.hasLocalAnswer && mailbox.isListPresentationReady)
        mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "t")]
        let selected = mailbox.selectedListRowIDs
        let box = mailbox.selectedMailbox
        await mailbox.triage.preparePermanentDeletion(in: .account("a", SystemLabel.trash),
            forRows: [.init(accountID: "a", threadID: "t4", messageID: "m5")])
        let review = try #require(mailbox.triage.deletionReview)
        #expect(review.approvals.count == 1)
        #expect(review.approvals.first?.messageIDs == ["m5"])
        #expect(review.approvals.first?.labelID == SystemLabel.trash)
        #expect(mailbox.selectedListRowIDs == selected)
        #expect(mailbox.selectedMailbox == box)
        #expect(mailbox.search.queryText == "Notes")
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })

        await mailbox.triage.preparePermanentDeletion(entireMailbox: true, in: .account("a", SystemLabel.spam))
        #expect(mailbox.triage.deletionReview?.approvals.first?.messageIDs == ["m7"])
        #expect(mailbox.selectedMailbox == box)
        #expect(mailbox.search.queryText == "Notes")
    }

    @Test func movingSnoozedMailToInboxEndsOnlyTheCapturedMessagesSnooze() async throws {
        let (mailbox, cache) = try await fixture(withStore: true)
        defer { Task { await mailbox.stop() } }
        let first = MailListRowID(accountID: "a", threadID: "t", messageID: "m1")
        let second = MailListRowID(accountID: "a", threadID: "t", messageID: "m2")
        await mailbox.snoozeRows([first, second], until: .now.addingTimeInterval(3600))?.value
        mailbox.selectedMailbox = .account("a", MailboxModel.snoozedID)
        mailbox.showMoveTo(forRows: [first])
        #expect(mailbox.move(to: "Label_c") == nil)
        #expect(mailbox.notice != nil)
        mailbox.search.update("Notes")
        mailbox.notice = nil
        mailbox.showMoveTo(forRows: [first])
        #expect(mailbox.moveSourceLabelID == nil)
        let queued = try await cache.read { try $0.pendingActions(accountID: "a").count }
        await mailbox.move(to: "Label_c")?.value
        #expect(mailbox.notice?.message.contains("snooze") == true)
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").count } == queued)
        #expect(try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a")["m1"] } == ["Label_a", "Label_b"])
        mailbox.search.cancel()
        mailbox.showMoveTo(forRows: [first])
        mailbox.selectedMailbox = .account("a", SystemLabel.inbox)
        await mailbox.move(to: SystemLabel.inbox)?.value
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"]?.contains(SystemLabel.inbox) == true)
        #expect(labels["m2"]?.contains(SystemLabel.inbox) == false)
        var snoozed = cache.messageListEntries(threadsByAccount: ["a": ["t"]], snoozedOnly: true).makeAsyncIterator()
        #expect(try await snoozed.next()?.map(\.message.id) == ["m2"])
    }

    @Test(arguments: [false, true])
    func detachedReaderMovesRespectMessageAndConversationSnoozes(wholeConversation: Bool) async throws {
        let remoteMessages: [[String: Any]] = ["m1", "m2"].map { id in
            ["id": id, "threadId": "t", "historyId": "1",
             "internalDate": String(Int64(Date.now.timeIntervalSince1970 * 1_000)),
             "labelIds": [SystemLabel.inbox, "Label_a", "Label_b"],
             "payload": ["headers": [["name": "Subject", "value": "Notes"],
                                       ["name": "From", "value": "sender@example.invalid"],
                                       ["name": "To", "value": "me@example.invalid"]]]]
        }
        let remoteThread = try JSONDecoder().decode(GmailThread.self,
            from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": remoteMessages]))
        let (mailbox, cache) = try await fixture(gmail: ContextTriageService(contextThread: remoteThread), withStore: true)
        defer { Task { await mailbox.stop() } }
        var stream = cache.thread(accountID: "a", threadID: "t").makeAsyncIterator()
        let detail = try #require(try await stream.next())
        let message = try #require(detail?.messages.first { $0.id == "m1" })
        let wake = Date.now.addingTimeInterval(3600)
        if wholeConversation {
            await mailbox.snooze([ThreadKey(accountID: "a", threadID: "t")], until: wake)?.value
        } else {
            await mailbox.snoozeRows([.init(accountID: "a", threadID: "t", messageID: "m1"),
                                     .init(accountID: "a", threadID: "t", messageID: "m2")], until: wake)?.value
        }
        // The detached reader's old snapshot and the main selection both omit the current snooze.
        mailbox.selectedMailbox = .account("a", "Label_b")
        mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "other")]
        await mailbox.moveMessage(message, to: "Label_c")?.value
        let heldLabels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(heldLabels["m1"] == ["Label_a", "Label_b"])
        #expect(mailbox.notice?.message.contains("snooze") == true)

        await mailbox.moveMessage(message, to: SystemLabel.inbox)?.value
        var snoozed = cache.messageListEntries(threadsByAccount: ["a": ["t"]], snoozedOnly: true).makeAsyncIterator()
        #expect(try await snoozed.next()?.map(\.message.id) == ["m2"])
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"]?.contains(SystemLabel.inbox) == true)
        #expect(labels["m2"]?.contains(SystemLabel.inbox) == false)

        let undo = UndoManager()
        mailbox.undoManager = undo
        await mailbox.moveMessage(message, to: "Label_c")?.value
        #expect(try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a")["m1"] } == ["Label_a", "Label_b", "Label_c"])
        #expect(undo.canUndo)
    }

    private func fixture(gmail: any GmailService = AuditGmail(), withStore: Bool = false) async throws -> (MailboxModel, MailCache) {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "a", email: "me@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        try await cache.write { tx in
            try tx.replaceLabels(["a", "b", "c"].map {
                LabelRecord(accountID: "a", id: "Label_" + $0, name: "Folder " + $0, isSystem: false)
            }, accountID: "a")
            _ = try tx.upsertMessages([("m1", "t"), ("m2", "t"), ("m3", "other")].map { id, thread in
                CacheTransaction.MessageUpdate(record: MessageRecord(accountID: "a", id: id, threadID: thread,
                    historyID: 1, date: .now, snippet: "", sender: "sender@example.invalid", recipients: account.email,
                    cc: nil, subject: "Notes", sizeEstimate: 10),
                    labelIDs: thread == "t" ? [SystemLabel.inbox, "Label_a", "Label_b"] : [SystemLabel.inbox])
            })
            try tx.rebuildThreads(["t", "other"], accountID: "a")
        }
        let defaults = try #require(UserDefaults(suiteName: "tern.context.tests." + UUID().uuidString))
        let store = withStore ? try AccountStore.inMemory() : nil
        try await store?.save(account)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: gmail,
            outgoingDirectory: FileManager.default.temporaryDirectory, snoozeStore: store, syncEnabled: false,
            listPreferences: MessageListPreferences(defaults: defaults))
        await mailbox.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.labels.count != 3 || !mailbox.isListPresentationReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(mailbox.labels.count == 3)
        try #require(mailbox.isListPresentationReady)
        return (mailbox, cache)
    }
}

/// Preparation reads synthetic Gmail metadata; destructive writes fail if reached.
private struct ContextTriageService: GmailService, TriageService {
    let base = AuditGmail()
    var contextThread: GmailThread? = nil
    func profile() async throws -> GmailProfile { try await base.profile() }
    func labels() async throws -> [GmailLabel] { try await base.labels() }
    func labels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>] { try await base.labels(ids: ids) }
    func listMessages(query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> MessageListPage {
        try await base.listMessages(query: query, labelIDs: labelIDs, includeSpamTrash: includeSpamTrash, pageToken: pageToken, maxResults: maxResults)
    }
    func messages(ids: [String], format: MessageFormat, metadataHeaders: [String]) async throws -> [String: Result<GmailMessage, GmailError>] {
        let overrides = contextThread?.messages ?? []
        let overriddenIDs = Set(overrides.map(\.id))
        var results = try await base.messages(ids: ids.filter { !overriddenIDs.contains($0) }, format: format, metadataHeaders: metadataHeaders)
        for message in overrides where ids.contains(message.id) { results[message.id] = .success(message) }
        return results
    }
    func thread(id: String, format: MessageFormat) async throws -> GmailThread {
        if let contextThread, contextThread.id == id { return contextThread }
        return try await base.thread(id: id, format: format)
    }
    func listThreads(query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadListPage {
        try await base.listThreads(query: query, labelIDs: labelIDs, includeSpamTrash: includeSpamTrash, pageToken: pageToken, maxResults: maxResults)
    }
    func threads(ids: [String], format: MessageFormat, metadataHeaders: [String]) async throws -> [String: Result<GmailThread, GmailError>] {
        var results = try await base.threads(ids: ids.filter { $0 != contextThread?.id }, format: format, metadataHeaders: metadataHeaders)
        if let contextThread, ids.contains(contextThread.id) { results[contextThread.id] = .success(contextThread) }
        return results
    }
    func attachment(messageID: String, attachmentID: String) async throws -> Data { try await base.attachment(messageID: messageID, attachmentID: attachmentID) }
    func attachmentMetadata(ids: [String]) async throws -> [String: Result<GmailMessage, GmailError>] { try await base.attachmentMetadata(ids: ids) }
    func attachmentHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage { try await base.attachmentHistory(startHistoryID: startHistoryID, pageToken: pageToken) }
    func history(startHistoryID: String, pageToken: String?) async throws -> HistoryPage { try await base.history(startHistoryID: startHistoryID, pageToken: pageToken) }
    func modifyThreads(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws -> LabelChangeResult {
        try await base.modifyThreads(ids: ids, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs)
    }
    func trashThreads(ids: [String]) async throws -> LabelChangeResult { try await base.trashThreads(ids: ids) }
    func untrashThreads(ids: [String]) async throws -> LabelChangeResult { try await base.untrashThreads(ids: ids) }
    func batchModifyMessages(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws -> LabelChangeResult {
        try await base.batchModifyMessages(ids: ids, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs)
    }
    func createLabel(name: String, color: LabelColor?) async throws -> GmailLabel { try await base.createLabel(name: name, color: color) }
    func patchLabel(id: String, name: String?, color: LabelColorChange?) async throws -> GmailLabel { try await base.patchLabel(id: id, name: name, color: color) }
    func deleteLabel(id: String) async throws { try await base.deleteLabel(id: id) }
    func drafts(query: String?, pageToken: String?, maxResults: Int) async throws -> DraftListPage { try await base.drafts(query: query, pageToken: pageToken, maxResults: maxResults) }
    func draft(id: String, format: MessageFormat) async throws -> GmailDraft { try await base.draft(id: id, format: format) }
    func createDraft(_ message: OutgoingMessage) async throws -> GmailDraft { try await base.createDraft(message) }
    func updateDraft(id: String, with message: OutgoingMessage) async throws -> GmailDraft { try await base.updateDraft(id: id, with: message) }
    func sendDraft(id: String, with message: OutgoingMessage) async throws -> GmailMessage { try await base.sendDraft(id: id, with: message) }
    func deleteDraft(id: String) async throws { try await base.deleteDraft(id: id) }
    func rawMessage(id: String) async throws -> Data { throw TriageError.unavailable }
    func batchDeleteMessages(ids: [String]) async throws { throw TriageError.unavailable }
    func trashMessages(ids: [String]) async throws -> [String: GmailError] { throw TriageError.unavailable }
    func untrashMessages(ids: [String]) async throws -> [String: GmailError] { throw TriageError.unavailable }
    func patchLabelVisibility(id: String, visibility: LabelListVisibility) async throws -> GmailLabel { throw TriageError.unavailable }
}
