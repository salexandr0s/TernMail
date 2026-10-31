import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

/// How long a sent message waits so Undo Send can stop it. Set in Settings.
enum UndoSendDelay {
    static let key = "undoSendDelay"
    static let choices = [5, 10, 20, 30]
    static let defaultSeconds = 10

    static var current: TimeInterval {
        let value = UserDefaults.standard.integer(forKey: key)
        return TimeInterval(choices.contains(value) ? value : defaultSeconds)
    }
}

/// Something to attach: a file, or data pasted or dropped without one.
enum Attachable: Sendable {
    case file(URL)
    case data(Data, filename: String, mimeType: String)

    var name: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .data(_, let filename, _): filename
        }
    }
}

/// One compose window. Edits are stored on this Mac within half a second, so
/// a crash or quit keeps them, and saved to Gmail once typing pauses.
@MainActor
@Observable
final class ComposeModel {
    enum Phase: Equatable {
        case loading
        case open
        /// Moving to another account. Nothing can change until the copy
        /// opens, so the copy misses no typing or file.
        case moving
        /// Sent, discarded or deleted. The window closes.
        case closed
        /// Moved to another account as the draft `localDraftID`, which the window shows instead.
        case moved(to: String)
    }

    struct Status: Equatable {
        var text: String
        var isError = false
    }

    /// What an alert says: what went wrong, then what to do or why.
    struct Problem: Equatable {
        var title: String
        var message: String
    }

    static let storeDelay: Duration = .milliseconds(500)
    static let autosaveDelay: Duration = .seconds(3)
    /// Typing that never pauses still saves to Gmail this often.
    static let longestUnsaved: TimeInterval = 30
    /// A discarded draft waits this long, so its notice can offer Undo.
    static let discardHold: TimeInterval = 10

    let localDraftID: String
    let mailbox: MailboxModel
    private let automaticAccountIDs: [String]

    private(set) var phase = Phase.loading
    private(set) var activity: DraftActivity?
    private(set) var senderChoices: [ComposeSender] = []
    var templates: [ComposeTemplate] = []
    var inlineImageData: [String: Data] = [:]
    var expandingGroups = 0
    var showsFormatting = UserDefaults.standard.bool(forKey: ComposePreferences.formatBarKey) {
        didSet { UserDefaults.standard.set(showsFormatting, forKey: ComposePreferences.formatBarKey) }
    }
    /// What the window shows. It runs ahead of the stored draft while edits wait to be stored.
    var content = DraftContent() {
        didSet {
            if !isApplyingStoredContent, content != oldValue { contentChanged() }
        }
    }
    var format = TextFormat()
    /// The cursor is in the message, so formatting has something to apply to.
    var isEditingMessage = false
    var showsCc = false
    var showsBcc = false
    /// The draft came from another app with formatting the editor can't keep.
    var droppedFormatting = false
    /// A problem to show in an alert, such as a missing recipient.
    var alert: Problem?
    /// Set by the toolbar or the menu bar to show the file picker or the link editor.
    var isChoosingFiles = false
    var isEditingLink = false
    private(set) var storeError: String?
    private(set) var hasPendingEdits = false
    /// Changed in this window, so closing it keeps the draft. The stored
    /// revision can trail a store that just finished, so it can't tell.
    private var isTouched = false
    /// Default sender insertion raises the stored revision without making the draft a user edit.
    @ObservationIgnored private var uneditedRevision = 0
    /// Changed since the last save to Gmail was asked for.
    private var changedSinceSave = false
    /// Files still being copied into the draft, which `attachments` doesn't list yet.
    private var attachmentsInProgress = 0
    @ObservationIgnored private let attachmentFiles: OutgoingAttachmentFiles

    @ObservationIgnored weak var editor: (any RichTextEditing)?
    @ObservationIgnored private var isApplyingStoredContent = false
    /// When the stored draft last changed, as far as this window knows. A newer
    /// stored draft with different content came from Gmail and replaces the window's.
    @ObservationIgnored private var knownUpdate = Date.distantPast
    @ObservationIgnored private var unsavedSince: Date?
    @ObservationIgnored private var storeTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var integrationRefresh: Task<Void, Never>?
    @ObservationIgnored private var featureObservation: Task<Void, Never>?
    @ObservationIgnored private var choseRecipientAccount = false
    @ObservationIgnored private var recipientAccountGeneration = 0
    @ObservationIgnored private var recipientAccountTask: Task<Void, Never>?
    @ObservationIgnored private var lastAutomaticRecipient: String?

    init(localDraftID: String, mailbox: MailboxModel) {
        self.localDraftID = localDraftID
        self.mailbox = mailbox
        attachmentFiles = OutgoingAttachmentFiles(localDraftID: localDraftID)
        switch mailbox.selectedMailbox {
        case .combined?, .scoped?: automaticAccountIDs = mailbox.selectedAccounts.map { $0.account.id }
        default: automaticAccountIDs = []
        }
    }

    var draft: LocalDraft? { activity?.draft }

    /// The draft's account, whose engine stores, saves and sends it. Nil
    /// until the draft loads, or once its account signs out.
    var owner: AccountMailbox? {
        draft.flatMap { mailbox.account(id: $0.accountID) }
    }

    var attachments: [OutgoingAttachment] { activity?.attachments ?? [] }

    var showsFrom: Bool { draft != nil }

    var accountChoices: [AccountRecord] { mailbox.accounts.map(\.account) }

    var fromEmail: String { content.fromAddress ?? owner?.account.email ?? "" }

    var selectedSender: ComposeSender? {
        senderChoices.first { $0.account.id == draft?.accountID && $0.identity.lowercasedAddress == fromEmail.lowercased() }
    }

    /// Only a new message can change accounts.
    var canChangeAccount: Bool { draft?.kind == .new }

    var isEditable: Bool { phase == .open && draft?.state == .editing }

    /// Edited here since the last save to Gmail. The window's close button shows a dot.
    var isEdited: Bool {
        isEditable && isTouched && (hasPendingEdits || changedSinceSave || draft?.hasUnsavedChanges == true)
    }

    var canFormat: Bool { isEditable && isEditingMessage }
    var canSendAndArchive: Bool { draft?.threadID != nil && isEditable }

    var progressText: String? {
        if expandingGroups > 0 { return "Loading contact group…" }
        if phase == .moving { return "Changing sender account…" }
        if attachmentsInProgress > 0 { return "Attaching files…" }
        return nil
    }

    var title: String {
        let subject = content.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? "New Message" : subject
    }

    var status: Status? {
        if let storeError { return Status(text: storeError, isError: true) }
        if let progressText { return Status(text: progressText) }
        guard let activity else { return nil }
        let draft = activity.draft
        switch draft.state {
        case .sending: return Status(text: "Sending")
        case .discarding: return Status(text: "Discarding")
        case .editing: break
        }
        if let error = draft.sendError { return Status(text: error, isError: true) }
        if activity.isWaitingToRetry { return Status(text: "Can't reach Gmail. Tern will keep trying.") }
        if activity.rows.contains(where: { $0.kind == .saveDraft }) { return Status(text: "Saving…") }
        if hasPendingEdits || draft.hasUnsavedChanges || draft.gmailDraftID == nil { return nil }
        return Status(text: "Saved to Drafts")
    }

    func start() {
        guard observation == nil, phase == .loading else { return }
        mailbox.composeOpened(self)
        droppedFormatting = mailbox.takeDroppedFormatting(localDraftID)
        let stream = mailbox.cache.draftActivity(localDraftID: localDraftID)
        observation = Task { [weak self] in
            do {
                for try await activity in stream {
                    guard let self, !Task.isCancelled else { return }
                    await apply(activity)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.storeError = "Tern couldn't read this draft."
            }
        }
    }

    private var excludedSuggestions: Set<String> {
        var excluded = Set<String>()
        for address in content.to { excluded.insert(address.normalized) }
        for address in content.cc { excluded.insert(address.normalized) }
        for address in content.bcc { excluded.insert(address.normalized) }
        for sender in senderChoices { excluded.insert(sender.identity.lowercasedAddress) }
        if let ownAddress = owner?.account.email { excluded.insert(ownAddress.lowercased()) }
        return excluded
    }

    /// Local correspondents and contacts appear without waiting for the directory.
    func suggestions(for text: String) async -> [EmailAddress] {
        guard let account = owner?.account else { return [] }
        let current = try? await mailbox.accountStore?.accounts().first(where: { $0.id == account.id })
        let contacts = current.map { AccountFeature.named($0.enabledFeatures).contains(.contacts) } ?? false
        var excluded = excludedSuggestions
        excluded.formUnion((try? await mailbox.accountStore?.blockedSuggestionAddresses(accountID: account.id)) ?? [])
        let found = try? await mailbox.cache.recipientSuggestions(
            accountID: account.id, matching: text, excluding: excluded, includeContacts: contacts
        )
        guard !Task.isCancelled, draft?.accountID == account.id else { return [] }
        if contacts {
            let latest = try? await mailbox.accountStore?.accounts().first(where: { $0.id == account.id })
            if latest.map({ AccountFeature.named($0.enabledFeatures).contains(.contacts) }) != true {
                return (try? await mailbox.cache.addressSuggestions(
                    accountID: account.id, matching: text, excluding: excluded
                )) ?? []
            }
        }
        let latestBlocked = (try? await mailbox.accountStore?.blockedSuggestionAddresses(accountID: account.id)) ?? []
        return (found ?? []).filter { !excludedSuggestions.contains($0.normalized) && !latestBlocked.contains($0.normalized) }
    }

    func directorySuggestions(for text: String) async -> [EmailAddress] {
        guard let owner else { return [] }
        var excluded = excludedSuggestions
        excluded.formUnion((try? await mailbox.accountStore?.blockedSuggestionAddresses(accountID: owner.account.id)) ?? [])
        let found = await owner.directorySuggestions(for: text, accounts: mailbox.accountStore, excluding: excluded)
        let latestBlocked = (try? await mailbox.accountStore?.blockedSuggestionAddresses(accountID: owner.account.id)) ?? []
        return found.filter { !excludedSuggestions.contains($0.normalized) && !latestBlocked.contains($0.normalized) }
    }

    func selectSender(_ sender: ComposeSender) {
        guard isEditable, senderChoices.contains(where: { $0.id == sender.id }), let draft else { return }
        choseRecipientAccount = true
        recipientAccountGeneration += 1
        recipientAccountTask?.cancel()
        guard sender.account.id == draft.accountID else {
            move(to: sender.account.id, sender: sender)
            return
        }
        guard sender.identity.lowercasedAddress != fromEmail.lowercased() else { return }
        var changed = content
        changed.fromAddress = sender.address
        changed.signatureHTML = sender.signature(for: draft.kind)
        content = changed
        serially { [self] in
            guard let store = mailbox.accountStore,
                  let signature = try? await store.composeSignature(accountID: sender.account.id, address: sender.address, kind: draft.kind),
                  fromEmail.lowercased() == sender.identity.lowercasedAddress else { return }
            content.signatureHTML = signature.html
            content.signatureAboveQuote = signature.aboveQuote
            content.signatureSeparator = signature.separator
        }
    }

    // MARK: Actions

    /// Queues the message to send after the undo delay. Returns true when the
    /// window can close.
    @discardableResult
    func send(archive: Bool = false) async -> Bool {
        guard isEditable else { return false }
        guard expandingGroups == 0 else {
            alert = Problem(title: "Can't Send Yet", message: "Wait for the contact group to finish loading.")
            return false
        }
        let recipients = content.to + content.cc + content.bcc
        if recipients.isEmpty {
            alert = Problem(title: "Can't Send Message", message: "Add at least one recipient.")
            return false
        }
        if let invalid = recipients.first(where: { !$0.isValid }) {
            alert = Problem(title: "Can't Send Message", message: "“\(invalid.address)” isn't a valid email address.")
            return false
        }
        guard let engine = owner?.engine else { return false }
        content.archiveAfterSend = archive && draft?.threadID != nil
        cancelTimers()
        let id = localDraftID
        let delay = UndoSendDelay.current
        let queued = await serially { [self] in
            do {
                return try await engine.sendDraft(id, content: content, delay: delay)
            } catch {
                storeError = "Tern couldn't send this message."
                return false
            }
        }.value
        if queued {
            mailbox.didQueueSend(id, delay: delay)
            close()
        }
        return queued
    }

    /// Queues the draft's deletion, held briefly so it can be undone.
    @discardableResult
    func discard() async -> Bool {
        guard isEditable else { return false }
        guard let engine = owner?.engine else { return false }
        cancelTimers()
        let id = localDraftID
        // Stores the last edits too, so Undo brings them back.
        let queued = await serially { [self] in
            (try? await engine.discardDraft(id, content: content, hold: Self.discardHold)) ?? false
        }.value
        if queued {
            mailbox.didQueueDiscard(id, hold: Self.discardHold)
            close()
        }
        return queued
    }

    /// Moves a new message to another account, after any edits and files
    /// still on their way. The window then shows the copy.
    func move(to accountID: String, sender: ComposeSender? = nil, isAutomatic: Bool = false) {
        guard isEditable, canChangeAccount, accountID != draft?.accountID,
              let engine = owner?.engine, let destination = mailbox.account(id: accountID)
        else { return }
        if !isAutomatic {
            choseRecipientAccount = true
            recipientAccountGeneration += 1
            recipientAccountTask?.cancel()
        }
        let id = localDraftID
        phase = .moving
        serially { [self] in
            // A move that fails or doesn't happen opens the window again.
            defer { if phase == .moving { phase = .open } }
            do {
                let target = sender ?? ComposeSender.preferred(
                    in: senderChoices.filter { $0.account.id == accountID }, original: nil, kind: .new
                )
                var movedContent = content
                movedContent.fromAddress = target?.address ?? destination.account.email
                movedContent.signatureHTML = target?.signature(for: .new)
                if let target, let store = mailbox.accountStore,
                   let signature = try? await store.composeSignature(accountID: accountID, address: target.address, kind: .new) {
                    movedContent.signatureHTML = signature.html
                    movedContent.signatureAboveQuote = signature.aboveQuote
                    movedContent.signatureSeparator = signature.separator
                }
                guard phase == .moving, let moved = try await engine.moveDraft(id, content: movedContent, to: destination.engine) else { return }
                cancelTimers()
                observation?.cancel()
                phase = .moved(to: moved.id)
            } catch let error as ComposeError {
                alert = Problem(title: "Can't Change Account", message: error.errorDescription ?? "")
            } catch {
                alert = Problem(title: "Can't Change Account",
                                message: "Tern couldn't move this message to \(destination.account.email).")
            }
        }
    }

    /// Copies the files into the draft, one at a time, in order.
    func attach(_ items: [Attachable], inlineImages: Bool = false) {
        guard isEditable, !items.isEmpty else { return }
        markChanged()
        guard let engine = owner?.engine else { return }
        let id = localDraftID
        for item in items {
            attachmentsInProgress += 1
            serially { [self] in
                defer { attachmentsInProgress -= 1 }
                do {
                    let attached: OutgoingAttachment?
                    switch item {
                    case .file(let url):
                        attached = try await engine.attachFile(at: url, to: id)
                    case .data(let data, let filename, let mimeType):
                        attached = try await engine.attachData(data, filename: filename, mimeType: mimeType, to: id)
                    }
                    if inlineImages, let attached, let image = try await engine.markInlineImage(attached), let cid = image.contentID {
                        let bytes = try await engine.outgoingAttachmentData(image)
                        inlineImageData[cid] = bytes
                        let reference = InlineImageReference(contentID: cid, altText: image.filename)
                        if let editor { editor.insertImage(reference, data: bytes) }
                        else { content.body.blocks.append(.init(runs: [.init("", image: reference)])) }
                    }
                } catch let error as ComposeError {
                    alert = Problem(title: "Can't Attach File", message: error.errorDescription ?? "")
                } catch {
                    alert = Problem(title: "Can't Attach File", message: "Tern couldn't attach “\(item.name)”.")
                }
            }
        }
        scheduleAutosave()
    }

    func removeAttachment(_ attachment: OutgoingAttachment) {
        guard isEditable, let rowID = attachment.id else { return }
        markChanged()
        attachmentFiles.remove(attachment)
        guard let engine = owner?.engine else { return }
        serially { [self] in
            do {
                try await engine.removeAttachment(id: rowID)
            } catch {
                alert = Problem(title: "Can't Remove File", message: "Tern couldn't remove “\(attachment.filename)”.")
            }
        }
        scheduleAutosave()
    }

    /// A copy of the file under its own name, for Quick Look, dragging out and
    /// Finder. Nil when the file can't be read.
    func attachmentFileURL(_ attachment: OutgoingAttachment) async -> URL? {
        guard let engine = owner?.engine else { return nil }
        return await attachmentFiles.url(for: attachment) { try await engine.outgoingAttachmentData(attachment) }
    }

    /// Keeps `address` out of this account's recipient suggestions.
    func blockSuggestion(_ address: EmailAddress) async {
        guard address.isValid, let accountID = draft?.accountID, let store = mailbox.accountStore else { return }
        do {
            try await store.setSuggestionBlocked(true, address: address.address, accountID: accountID)
        } catch {
            alert = Problem(title: "Can't Add to Blocklist", message: "Tern couldn't save the change. Try again.")
        }
    }

    /// Saves to Gmail now.
    func save() {
        guard isEditable else { return }
        saveNow()
    }

    /// The window closed. An untouched draft that never reached Gmail goes
    /// away; anything else stays in Drafts.
    func windowClosed() {
        observation?.cancel()
        integrationRefresh?.cancel()
        featureObservation?.cancel()
        recipientAccountTask?.cancel()
        attachmentFiles.removeAll()
        guard isEditable else { return }
        phase = .closed
        keepOrDiscard()
    }

    /// Before quitting: keeps or discards the draft as closing the window
    /// would, then waits until that is stored. A kept draft goes to Gmail,
    /// so it shows in Drafts even when its window isn't restored.
    func prepareToQuit() async {
        if isEditable { keepOrDiscard() }
        await lastWrite?.value
    }

    private func keepOrDiscard() {
        guard let draft else { return }
        let isBlank = content.to.isEmpty && content.cc.isEmpty && content.bcc.isEmpty
            && content.subject.trimmingCharacters(in: .whitespaces).isEmpty && content.body.isEmpty
            && attachments.isEmpty && attachmentsInProgress == 0
        let untouched = draft.revision == uneditedRevision && !isTouched
        if draft.gmailDraftID == nil, untouched || isBlank {
            cancelTimers()
            guard let engine = owner?.engine else { return }
            let id = localDraftID
            serially { _ = try? await engine.discardDraft(id, hold: 0) }
        } else if changedSinceSave || hasPendingEdits || draft.hasUnsavedChanges {
            saveNow()
        }
    }

    private func saveNow() {
        cancelTimers()
        unsavedSince = nil
        changedSinceSave = false
        guard let engine = owner?.engine else { return }
        let id = localDraftID
        serially { [self] in
            let content = content
            do {
                try await engine.saveDraft(id, content: content)
                if self.content == content { hasPendingEdits = false }
                storeError = nil
            } catch {
                storeError = "Tern couldn't save this draft on this Mac."
            }
        }
    }

    /// A link target from what the person typed: a web address, with
    /// `https://` added when missing, or an email address.
    static func linkURL(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return url
        }
        if EmailAddress(address: text).isValid { return URL(string: "mailto:\(text)") }
        guard let url = URL(string: "https://\(text)"), let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    // MARK: Private

    private func apply(_ activity: DraftActivity?) async {
        guard let activity else {
            // Sent or discarded, from this window or the Outbox.
            self.activity = nil
            close()
            return
        }
        self.activity = activity
        let draft = activity.draft
        if phase == .loading {
            // A restored or moved draft already has a chosen sender snapshot.
            choseRecipientAccount = draft.fromAddress != nil
            replaceContent(with: draft.content)
            showsCc = !draft.cc.isEmpty
            showsBcc = !draft.bcc.isEmpty
            knownUpdate = draft.updatedAt
            await loadSenders()
            await loadComposeFeatures()
            guard !Task.isCancelled, phase == .loading else { return }
            await initializeSender(for: draft)
            guard !Task.isCancelled, phase == .loading else { return }
            phase = .open
            refreshIntegrations()
            featureObservation = Task { [weak self] in
                let updates = NotificationCenter.default.notifications(named: .ternComposePreferencesChanged).map { _ in true }
                for await _ in updates {
                    guard let self, !Task.isCancelled else { return }
                    await loadComposeFeatures()
                }
            }
        } else if draft.updatedAt > knownUpdate {
            knownUpdate = draft.updatedAt
            // Imported from Gmail after another app changed it.
            if !hasPendingEdits, draft.content != content { replaceContent(with: draft.content) }
        }
        if let engine = owner?.engine {
            for attachment in activity.attachments where attachment.contentID != nil {
                if let cid = attachment.contentID, inlineImageData[cid] == nil {
                    inlineImageData[cid] = try? await engine.outgoingAttachmentData(attachment)
                }
            }
        }
    }

    private func loadSenders() async {
        let stored = (try? await mailbox.accountStore?.accounts()) ?? []
        var choices: [ComposeSender] = []
        for owner in mailbox.accounts where canChangeAccount || owner.account.id == draft?.accountID {
            let account = stored.first { $0.id == owner.account.id } ?? owner.account
            let identities = (try? await mailbox.accountStore?.identities(accountID: account.id)) ?? []
            choices += ComposeSender.choices(account: account, identities: identities)
        }
        guard !Task.isCancelled else { return }
        senderChoices = choices
    }

    private func initializeSender(for draft: LocalDraft) async {
        guard draft.revision == 0, draft.gmailDraftID == nil, content.fromAddress == nil,
              draft.kind != .edit, draft.kind != .invitationReply, !isTouched else { return }
        let original: MessageRecord?
        if let sourceID = draft.sourceMessageID {
            original = try? await mailbox.cache.read { try $0.message(id: sourceID, accountID: draft.accountID) }
        } else { original = nil }
        guard !Task.isCancelled, !isTouched,
              let sender = ComposeSender.preferred(
                in: senderChoices.filter { $0.account.id == draft.accountID }, original: original, kind: draft.kind
              ) else { return }
        var initialized = content
        initialized.fromAddress = sender.address
        initialized.signatureHTML = sender.signature(for: draft.kind)
        initialized.composeFont = ComposePreferences.font
        if let store = mailbox.accountStore,
           let signature = try? await store.composeSignature(accountID: draft.accountID, address: sender.address, kind: draft.kind) {
            initialized.signatureHTML = signature.html
            initialized.signatureAboveQuote = signature.aboveQuote
            initialized.signatureSeparator = signature.separator
        }
        guard let engine = owner?.engine else { return }
        do {
            guard let stored = try await engine.updateDraft(localDraftID, content: initialized), !Task.isCancelled else { return }
            activity?.draft = stored
            knownUpdate = max(knownUpdate, stored.updatedAt)
            uneditedRevision = stored.revision
            replaceContent(with: initialized)
        } catch {
            storeError = "Tern couldn't save this draft's sender on this Mac."
        }
    }

    private func refreshIntegrations() {
        integrationRefresh?.cancel()
        integrationRefresh = Task { [weak self] in
            guard let self else { return }
            for owner in mailbox.accounts where canChangeAccount || owner.account.id == draft?.accountID {
                guard !Task.isCancelled else { return }
                try? await owner.engine.refreshIdentities(olderThan: 24 * 60 * 60)
                try? await owner.engine.syncContacts(olderThan: 10 * 60)
            }
            await loadSenders()
        }
    }

    private func replaceContent(with stored: DraftContent) {
        isApplyingStoredContent = true
        content = stored
        isApplyingStoredContent = false
    }

    private func markChanged() {
        isTouched = true
        changedSinceSave = true
    }

    private func contentChanged() {
        guard isEditable else { return }
        markChanged()
        hasPendingEdits = true
        if storeTask == nil {
            storeTask = Task { [weak self] in
                try? await Task.sleep(for: Self.storeDelay)
                guard let self, !Task.isCancelled else { return }
                storeTask = nil
                store()
            }
        }
        scheduleAutosave()
        chooseRecipientAccountIfNeeded()
    }

    /// Saves to Gmail once edits pause, or at once when they haven't paused for a while.
    private func scheduleAutosave() {
        let now = Date()
        let since = unsavedSince ?? now
        unsavedSince = since
        autosaveTask?.cancel()
        let delay = now.timeIntervalSince(since) >= Self.longestUnsaved ? Duration.zero : Self.autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            autosaveTask = nil
            if shouldSaveToGmail { save() }
        }
    }

    /// A new message that is still blank stays on this Mac.
    private var shouldSaveToGmail: Bool {
        draft?.gmailDraftID != nil || !content.to.isEmpty || !content.cc.isEmpty || !content.bcc.isEmpty
            || !content.subject.isEmpty || !content.body.isEmpty || !attachments.isEmpty || attachmentsInProgress > 0
    }

    private func store() {
        guard let engine = owner?.engine else { return }
        let id = localDraftID
        serially { [self] in
            let content = content
            do {
                guard let stored = try await engine.updateDraft(id, content: content) else { return }
                knownUpdate = max(knownUpdate, stored.updatedAt)
                if self.content == content { hasPendingEdits = false }
                storeError = nil
            } catch {
                storeError = "Tern couldn't save this draft on this Mac."
            }
        }
    }

    private func cancelTimers() {
        storeTask?.cancel()
        storeTask = nil
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    private func close() {
        cancelTimers()
        observation?.cancel()
        integrationRefresh?.cancel()
        featureObservation?.cancel()
        recipientAccountTask?.cancel()
        attachmentFiles.removeAll()
        phase = .closed
    }

    func insertTemplate(_ template: ComposeTemplate) {
        guard isEditable else { return }
        if let editor { editor.insertDocument(template.document) }
        else { content.body.blocks += template.document.blocks }
    }

    private func loadComposeFeatures() async {
        templates = (try? await mailbox.accountStore?.composeTemplates()) ?? []
    }

    private func chooseRecipientAccountIfNeeded() {
        guard !choseRecipientAccount, canChangeAccount, ComposePreferences.defaultAccountID == nil,
              automaticAccountIDs.count > 1, let recipient = content.to.first, recipient.isValid else { return }
        guard recipient.normalized != lastAutomaticRecipient else { return }
        lastAutomaticRecipient = recipient.normalized
        recipientAccountGeneration += 1
        let generation = recipientAccountGeneration
        recipientAccountTask?.cancel()
        let ids = automaticAccountIDs
        recipientAccountTask = Task { [weak self] in
            guard let self,
                  let target = try? await mailbox.cache.lastCorrespondenceAccount(with: recipient.address, accountIDs: ids),
                  !Task.isCancelled, generation == recipientAccountGeneration, !choseRecipientAccount,
                  content.to.first?.normalized == recipient.normalized, isEditable, canChangeAccount else { return }
            if target != draft?.accountID { move(to: target, isAutomatic: true) }
        }
    }

    /// Runs stores, saves, sends and discards one at a time, in the order asked.
    @discardableResult
    private func serially<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = lastWrite
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        lastWrite = Task { _ = await task.value }
        return task
    }
}
