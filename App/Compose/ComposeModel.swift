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
    case dropped(ComposeDroppedFile)
    case data(Data, filename: String, mimeType: String)

    var name: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .dropped(let file): file.filename
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

    /// A file the window couldn't attach or remove. It stays in the list,
    /// marked as failed, until Retry works or it's dismissed: a file that
    /// wasn't attached stays out, and one that wasn't removed stays attached.
    struct FailedAttachment: Identifiable {
        enum Action {
            case attach(Attachable, inlineImage: Bool)
            case remove(OutgoingAttachment)
        }

        let id = UUID()
        let action: Action
        /// What went wrong, shown as the file's help text.
        let reason: String

        var filename: String {
            switch action {
            case .attach(let item, _): item.name
            case .remove(let attachment): attachment.filename
            }
        }

        /// The attachment a failed removal left in the draft.
        var removedID: Int64? {
            guard case .remove(let attachment) = action else { return nil }
            return attachment.id
        }

        var isRemoval: Bool { removedID != nil }
    }

    /// A file being copied into the draft, which `attachments` doesn't list yet.
    private struct CopyingFile {
        let id = UUID()
        let name: String
    }

    /// A sender the window picked by itself for the first recipient. The
    /// copy the move makes shows it, and Undo moves the message back.
    struct SenderChange: Equatable {
        let accountName: String
        let recipient: EmailAddress
        let previousAccountID: String
        let previousAccountName: String
        let previousAddress: String

        var note: String {
            "Sending from \(accountName) because your last email with \(recipient.name ?? recipient.address) is there."
        }
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
    var isEditingLink = false {
        didSet { if isEditingLink, !oldValue { linkAnchor = editor?.selectionRect } }
    }
    /// The selection the link editor points at, read as it opens, in the
    /// message editor's coordinates. Nil points it at the whole editor.
    private(set) var linkAnchor: CGRect?
    private(set) var storeError: String?
    private(set) var hasPendingEdits = false
    /// Shown until it's undone, another sender is picked or the first recipient changes.
    private(set) var senderChange: SenderChange?
    /// What the copy made by an automatic move shows about it.
    @ObservationIgnored private(set) var copySenderChange: SenderChange?
    /// Changed in this window, so closing it keeps the draft. The stored
    /// revision can trail a store that just finished, so it can't tell.
    private var isTouched = false
    /// Default sender insertion raises the stored revision without making the draft a user edit.
    @ObservationIgnored private var uneditedRevision = 0
    /// Changed since the last save to Gmail was asked for.
    private var changedSinceSave = false
    /// Files still being copied into the draft, which `attachments` doesn't list yet.
    private var copying: [CopyingFile] = []
    /// Files that failed to attach or to be removed, listed with the attachments.
    private(set) var failedAttachments: [FailedAttachment] = []
    /// Storing the draft before the window closes, so nothing changes meanwhile.
    private(set) var isClosing = false
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

    init(localDraftID: String, mailbox: MailboxModel, senderChange: SenderChange? = nil) {
        self.localDraftID = localDraftID
        self.mailbox = mailbox
        attachmentFiles = OutgoingAttachmentFiles(localDraftID: localDraftID)
        self.senderChange = senderChange
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

    var isEditable: Bool { takesEdits && !isClosing }

    /// Open, and not taken by a send or discard.
    private var takesEdits: Bool { phase == .open && draft?.state == .editing }

    /// Closing the window now loses nothing. Otherwise `requestClose()`
    /// stores the draft first, and the window waits for it.
    var closesAtOnce: Bool {
        switch phase {
        case .open: !takesEdits
        case .moving: false
        case .loading, .closed, .moved: true
        }
    }

    /// Gmail doesn't have the latest changes, so closing the window saves
    /// them. The window's close button shows a dot meanwhile.
    var isEdited: Bool {
        guard isEditable, let draft else { return false }
        return closingAction(for: draft) == .save
    }

    var canFormat: Bool { isEditable && isEditingMessage }
    /// A new message gets a thread ID once Gmail saves it, but there is no
    /// earlier conversation to archive, and Send shouldn't change mid-draft.
    var canSendAndArchive: Bool { draft?.kind != .new && draft?.threadID != nil && isEditable }

    var progressText: String? {
        if isClosing { return "Saving draft…" }
        if expandingGroups > 0 { return "Loading contact group…" }
        if phase == .moving { return "Changing sender account…" }
        if let file = copying.first { return copying.count == 1 ? "Attaching “\(file.name)”…" : "Attaching \(copying.count) files…" }
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
        senderChange = nil
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
        if let hold = attachmentHold {
            alert = Problem(title: failedAttachments.isEmpty ? "Can't Send Yet" : "Can't Send Message", message: hold)
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
            // A file attached or removed just before may have failed meanwhile.
            if let hold = attachmentHold {
                alert = Problem(title: "Can't Send Message", message: hold)
                return false
            }
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
        } else if hasPendingEdits {
            // Send stopped the timer that would have stored them.
            store()
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
    /// still on their way. The window then shows the copy. A move the window
    /// makes by itself passes what the copy should say about it.
    func move(to accountID: String, sender: ComposeSender? = nil, automaticChange: SenderChange? = nil) {
        guard isEditable, canChangeAccount, accountID != draft?.accountID,
              let engine = owner?.engine, let destination = mailbox.account(id: accountID)
        else { return }
        if automaticChange == nil {
            choseRecipientAccount = true
            recipientAccountGeneration += 1
            recipientAccountTask?.cancel()
        }
        let id = localDraftID
        phase = .moving
        serially { [self] in
            // A move that fails or doesn't happen opens the window again.
            defer { if phase == .moving { phase = .open } }
            // The copy would lose a file that failed to attach or to be removed.
            if let hold = attachmentHold {
                if automaticChange == nil { alert = Problem(title: "Can't Change Account", message: hold) }
                return
            }
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
                copySenderChange = automaticChange
                phase = .moved(to: moved.id)
            } catch let error as ComposeError {
                alert = Problem(title: "Can't Change Account", message: error.errorDescription ?? "")
            } catch {
                alert = Problem(title: "Can't Change Account",
                                message: "Tern couldn't move this message to \(destination.account.email).")
            }
        }
    }

    /// Moves the message back to the sender it had before the window picked one.
    func undoSenderChange() {
        guard let change = senderChange else { return }
        let previous = senderChoices.first {
            $0.account.id == change.previousAccountID && $0.identity.lowercasedAddress == change.previousAddress.lowercased()
        }
        move(to: change.previousAccountID, sender: previous)
    }

    /// The previous account may have signed out since the window moved the message.
    var canUndoSenderChange: Bool {
        senderChange.map { mailbox.account(id: $0.previousAccountID) != nil } ?? false
    }

    /// Copies the files into the draft, one at a time, in order. A file that
    /// can't be copied stays listed as failed, with Retry.
    func attach(_ items: [Attachable], inlineImages: Bool = false) {
        guard isEditable, !items.isEmpty else { return }
        markChanged()
        guard let engine = owner?.engine else { return }
        let id = localDraftID
        for item in items {
            let file = CopyingFile(name: item.name)
            copying.append(file)
            serially { [self] in
                defer { copying.removeAll { $0.id == file.id } }
                let attached: OutgoingAttachment?
                do {
                    switch item {
                    case .file(let url):
                        attached = try await engine.attachFile(at: url, to: id)
                    case .dropped(let file):
                        attached = try await engine.attachFile(at: file.fileURL(), to: id)
                    case .data(let data, let filename, let mimeType):
                        attached = try await engine.attachData(data, filename: filename, mimeType: mimeType, to: id)
                    }
                } catch {
                    let reason = (error as? ComposeError)?.errorDescription
                        ?? (error as? ComposeFileDropError)?.errorDescription ?? "Tern couldn't attach “\(item.name)”."
                    failedAttachments.append(FailedAttachment(action: .attach(item, inlineImage: inlineImages), reason: reason))
                    return
                }
                guard inlineImages, let attached else { return }
                do {
                    guard let image = try await engine.markInlineImage(attached), let cid = image.contentID else { return }
                    let bytes = try await engine.outgoingAttachmentData(image)
                    inlineImageData[cid] = bytes
                    let reference = InlineImageReference(contentID: cid, altText: image.filename)
                    // A closing window's editor takes no edits, so the image goes in the content it stores.
                    if let editor, isEditable { editor.insertImage(reference, data: bytes) }
                    else { content.body.blocks.append(.init(runs: [.init("", image: reference)])) }
                } catch {
                    alert = Problem(title: "Can't Insert Image", message: "Tern couldn't place “\(attached.filename)” in the message.")
                }
            }
        }
        scheduleAutosave()
    }

    func removeAttachment(_ attachment: OutgoingAttachment) {
        guard isEditable, let rowID = attachment.id else { return }
        markChanged()
        failedAttachments.removeAll { $0.removedID == rowID }
        attachmentFiles.remove(attachment)
        guard let engine = owner?.engine else { return }
        serially { [self] in
            do {
                try await engine.removeAttachment(id: rowID)
            } catch {
                // Still attached, so it stays listed until Retry works or it's kept.
                failedAttachments.append(FailedAttachment(
                    action: .remove(attachment), reason: "Tern couldn't remove “\(attachment.filename)”."
                ))
            }
        }
        scheduleAutosave()
    }

    /// Tries a failed attach or removal again.
    func retry(_ failed: FailedAttachment) {
        guard isEditable, failedAttachments.contains(where: { $0.id == failed.id }) else { return }
        failedAttachments.removeAll { $0.id == failed.id }
        switch failed.action {
        case .attach(let item, let inlineImage): attach([item], inlineImages: inlineImage)
        case .remove(let attachment): removeAttachment(attachment)
        }
    }

    /// Takes a failed file off the list: one that wasn't attached stays out,
    /// and one that couldn't be removed stays attached.
    func dismissFailure(_ failed: FailedAttachment) {
        guard isEditable else { return }
        failedAttachments.removeAll { $0.id == failed.id }
    }

    /// What keeps the draft from going out or closing: a file that failed to
    /// attach or to be removed, or one still being copied in.
    private var attachmentHold: String? {
        if let failed = failedAttachments.first {
            return failed.isRemoval
                ? "“\(failed.filename)” couldn't be removed. Retry or keep it first."
                : "“\(failed.filename)” couldn't be attached. Retry or remove it first."
        }
        return copying.first.map { "Wait for “\($0.name)” to finish attaching." }
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
            alert = Problem(title: "Can't Hide This Address", message: "Tern couldn't save the change. Try again.")
        }
    }

    /// Saves to Gmail now.
    func save() {
        guard isEditable else { return }
        saveNow()
    }

    /// Closes the window once the draft is stored as closing leaves it: kept
    /// in Drafts with the latest edits, or removed when blank or untouched.
    /// A store that fails keeps the window open and says so, as does a file
    /// that failed or is still being copied in. Asking again while a close
    /// waits does nothing.
    func requestClose() async {
        guard isEditable, let draft else { return }
        if let hold = attachmentHold {
            alert = Problem(title: "Can't Close Message", message: hold)
            return
        }
        isClosing = true
        cancelTimers()
        let action = closingAction(for: draft)
        let problem = await serially { [self] in
            // A file attached or removed just before may have failed meanwhile.
            await storeForClosing(action) ?? attachmentHold.map { Problem(title: "Can't Close Message", message: $0) }
        }.value
        isClosing = false
        if let problem { alert = problem } else { close() }
    }

    /// The window went away. Its close button stored the draft already. Any
    /// other way, such as signing out, keeps or discards the draft as closing
    /// would, without waiting.
    func windowClosed() {
        observation?.cancel()
        integrationRefresh?.cancel()
        featureObservation?.cancel()
        recipientAccountTask?.cancel()
        attachmentFiles.removeAll()
        guard isEditable, let draft else { return }
        let action = closingAction(for: draft)
        phase = .closed
        cancelTimers()
        serially { [self] in _ = await storeForClosing(action) }
    }

    /// Before quitting: stores the draft as closing the window would, and
    /// waits for that. A kept draft goes to Gmail, so it shows in Drafts even
    /// when its window isn't restored. False when it couldn't be stored, or a
    /// file failed to attach or to be removed; the window then stays as it
    /// was, showing why.
    func prepareToQuit() async -> Bool {
        guard takesEdits, let draft else {
            await lastWrite?.value
            return true
        }
        cancelTimers()
        let action = closingAction(for: draft)
        return await serially { [self] in
            // The draft goes first, so quitting anyway keeps its text.
            await storeForClosing(action) == nil && attachmentHold == nil
        }.value
    }

    /// Stores the draft as `action` leaves it, after the edits and files
    /// queued before. Callers decide `action` when the close is asked for,
    /// while a file still being copied in counts: the attachment list shows
    /// it only later. Returns what keeps the window open instead, or nil.
    private func storeForClosing(_ action: ClosingAction) async -> Problem? {
        guard let engine = owner?.engine else { return nil }
        switch action {
        case .discard:
            // Blank or untouched, so a discard that fails loses nothing.
            _ = try? await engine.discardDraft(localDraftID, hold: 0)
        case .save:
            do {
                // Edits made while the store ran go too.
                var stored: DraftContent
                repeat {
                    stored = content
                    try await engine.saveDraft(localDraftID, content: stored)
                } while content != stored
                hasPendingEdits = false
                changedSinceSave = false
                unsavedSince = nil
                storeError = nil
            } catch {
                storeError = "Tern couldn't save this draft on this Mac."
                return Problem(title: "Can't Close Message",
                               message: "Tern couldn't save this draft on this Mac, so the window stays open. Try closing it again.")
            }
        case .keep:
            break
        }
        return nil
    }

    private enum ClosingAction {
        case discard, save, keep
    }

    /// A message that never reached Gmail goes away when it's blank or nobody
    /// changed it. Any other draft is saved when Gmail lacks its latest changes.
    private func closingAction(for draft: LocalDraft) -> ClosingAction {
        if draft.gmailDraftID == nil {
            let isBlank = content.to.isEmpty && content.cc.isEmpty && content.bcc.isEmpty
                && content.subject.trimmingCharacters(in: .whitespaces).isEmpty && content.body.isEmpty
                && attachments.isEmpty && copying.isEmpty && failedAttachments.isEmpty
            let untouched = draft.revision == uneditedRevision && !isTouched
            if untouched || isBlank { return .discard }
        }
        return changedSinceSave || hasPendingEdits || draft.hasUnsavedChanges ? .save : .keep
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
        if let senderChange, content.to.first?.normalized != senderChange.recipient.normalized { self.senderChange = nil }
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
            || !content.subject.isEmpty || !content.body.isEmpty || !attachments.isEmpty || !copying.isEmpty
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
                  content.to.first?.normalized == recipient.normalized, isEditable, canChangeAccount,
                  target != draft?.accountID, let owner, let destination = mailbox.account(id: target) else { return }
            move(to: target, automaticChange: SenderChange(
                accountName: destination.account.displayName ?? destination.account.email, recipient: recipient,
                previousAccountID: owner.account.id, previousAccountName: owner.account.displayName ?? owner.account.email,
                previousAddress: fromEmail
            ))
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
