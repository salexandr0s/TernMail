import Foundation
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

/// One compose window. Edits are stored on this Mac within half a second, so
/// a crash or quit keeps them, and saved to Gmail once typing pauses.
@MainActor
@Observable
final class ComposeModel {
    enum Phase: Equatable {
        case loading
        case open
        /// Sent, discarded or deleted. The window closes.
        case closed
    }

    struct Status: Equatable {
        var text: String
        var isError = false
    }

    static let storeDelay: Duration = .milliseconds(500)
    static let autosaveDelay: Duration = .seconds(3)
    /// Typing that never pauses still saves to Gmail this often.
    static let longestUnsaved: TimeInterval = 30
    /// A discarded draft waits this long, so its notice can offer Undo.
    static let discardHold: TimeInterval = 10

    let localDraftID: String
    private let mailbox: MailboxModel

    private(set) var phase = Phase.loading
    private(set) var activity: DraftActivity?
    /// What the window shows. It runs ahead of the stored draft while edits wait to be stored.
    var content = DraftContent() {
        didSet {
            if !isApplyingStoredContent, content != oldValue { contentChanged() }
        }
    }
    var format = TextFormat()
    var showsCc = false
    var showsBcc = false
    /// The draft came from another app with formatting the editor can't keep.
    var droppedFormatting = false
    /// A problem to show in an alert, such as a missing recipient.
    var alert: String?
    private(set) var storeError: String?
    private(set) var hasPendingEdits = false

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

    init(localDraftID: String, mailbox: MailboxModel) {
        self.localDraftID = localDraftID
        self.mailbox = mailbox
    }

    var draft: LocalDraft? { activity?.draft }

    var isEditable: Bool { phase == .open && draft?.state == .editing }

    var title: String {
        let subject = content.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? "New Message" : subject
    }

    var status: Status? {
        if let storeError { return Status(text: storeError, isError: true) }
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
        droppedFormatting = mailbox.takeDroppedFormatting(localDraftID)
        let stream = mailbox.cache.draftActivity(localDraftID: localDraftID)
        observation = Task { [weak self] in
            do {
                for try await activity in stream {
                    guard let self, !Task.isCancelled else { return }
                    apply(activity)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.storeError = "Tern couldn't read this draft."
            }
        }
    }

    /// Addresses from stored mail for a recipient being typed, leaving out
    /// this account and the recipients already added.
    func suggestions(for text: String) async -> [EmailAddress] {
        let account = mailbox.account
        let excluded = Set((content.to + content.cc + content.bcc).map(\.normalized) + [account.email.lowercased()])
        let found = try? await mailbox.cache.addressSuggestions(accountID: account.id, matching: text, excluding: excluded)
        return found ?? []
    }

    // MARK: Actions

    /// Queues the message to send after the undo delay. Returns true when the
    /// window can close.
    @discardableResult
    func send() async -> Bool {
        guard isEditable else { return false }
        let recipients = content.to + content.cc + content.bcc
        if recipients.isEmpty {
            alert = "Add at least one recipient."
            return false
        }
        if let invalid = recipients.first(where: { !$0.isValid }) {
            alert = "“\(invalid.address)” isn't a valid email address."
            return false
        }
        cancelTimers()
        let engine = mailbox.engine
        let id = localDraftID
        let queued = await serially { [self] in
            do {
                return try await engine.sendDraft(id, content: content, delay: UndoSendDelay.current)
            } catch {
                storeError = "Tern couldn't send this message."
                return false
            }
        }.value
        if queued { close() }
        return queued
    }

    /// Queues the draft's deletion, held briefly so it can be undone.
    @discardableResult
    func discard() async -> Bool {
        guard isEditable else { return false }
        cancelTimers()
        let engine = mailbox.engine
        let id = localDraftID
        let queued = await serially {
            (try? await engine.discardDraft(id, hold: Self.discardHold)) ?? false
        }.value
        if queued { close() }
        return queued
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
        guard isEditable, let draft else { return }
        phase = .closed
        let isBlank = content.to.isEmpty && content.cc.isEmpty && content.bcc.isEmpty
            && content.subject.trimmingCharacters(in: .whitespaces).isEmpty && content.body.isEmpty
        let untouched = draft.revision == 0 && !hasPendingEdits
        if draft.gmailDraftID == nil, untouched || isBlank {
            cancelTimers()
            let engine = mailbox.engine
            let id = localDraftID
            serially { _ = try? await engine.discardDraft(id, hold: 0) }
        } else if hasPendingEdits || draft.hasUnsavedChanges {
            saveNow()
        }
    }

    private func saveNow() {
        cancelTimers()
        unsavedSince = nil
        let engine = mailbox.engine
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

    private func apply(_ activity: DraftActivity?) {
        guard let activity else {
            // Sent or discarded, from this window or the Outbox.
            self.activity = nil
            close()
            return
        }
        self.activity = activity
        let draft = activity.draft
        if phase == .loading {
            replaceContent(with: draft.content)
            showsCc = !draft.cc.isEmpty
            showsBcc = !draft.bcc.isEmpty
            knownUpdate = draft.updatedAt
            phase = .open
        } else if draft.updatedAt > knownUpdate {
            knownUpdate = draft.updatedAt
            // Imported from Gmail after another app changed it.
            if !hasPendingEdits, draft.content != content { replaceContent(with: draft.content) }
        }
    }

    private func replaceContent(with stored: DraftContent) {
        isApplyingStoredContent = true
        content = stored
        isApplyingStoredContent = false
    }

    private func contentChanged() {
        guard isEditable else { return }
        hasPendingEdits = true
        let now = Date()
        let since = unsavedSince ?? now
        unsavedSince = since
        if storeTask == nil {
            storeTask = Task { [weak self] in
                try? await Task.sleep(for: Self.storeDelay)
                guard let self, !Task.isCancelled else { return }
                storeTask = nil
                store()
            }
        }
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
            || !content.subject.isEmpty || !content.body.isEmpty
    }

    private func store() {
        let engine = mailbox.engine
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
        phase = .closed
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
