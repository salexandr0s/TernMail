import Accessibility
import Foundation
import MailStore
import MessageContent
import Observation
import SyncEngine

/// The window's mailbox: what the sidebar, thread list and commands read,
/// and the actions they send to each account's sync engine.
@MainActor
@Observable
final class MailboxModel {
    /// A short message at the bottom of the window, with Undo when it can be reverted.
    struct Notice: Identifiable, Equatable {
        enum Undo: Equatable {
            case action(ActionReceipt)
            case send(localDraftID: String)
            case discard(localDraftID: String)
        }

        let id = UUID()
        let message: String
        var undo: Undo?
        var isError = false
        /// How long it stays up. Nil uses the toast default for its kind.
        var duration: Duration?
    }

    static let pageSize = 200
    static let undoLimit = 100
    /// The sidebar's Outbox, which isn't a Gmail label.
    static let outboxID = "TERN_OUTBOX"
    /// The sidebar's Snoozed, which Tern keeps itself since Gmail's API has none.
    nonisolated static let snoozedID = "TERN_SNOOZED"
    /// Received attachments, downloaded when opened. Signing out deletes them.
    static let defaultDownloadsDirectory = URL.cachesDirectory.appending(path: "Tern/Attachments", directoryHint: .isDirectory)

    /// Where a compose window's draft comes from.
    enum ComposeStart: Equatable {
        case newMessage
        case reply(ReplyKind, messageID: String)
        /// A Gmail draft shown in a thread.
        case editDraft(messageID: String)
    }

    /// The signed-in account.
    let primary: AccountMailbox
    /// Compose windows read and edit their drafts through these directly.
    let cache: MailCache
    var engine: SyncEngine { primary.engine }
    var account: AccountRecord { primary.account }
    let downloadsDirectory: URL
    /// While the search field has text, the list shows its results.
    let search: SearchModel

    var selectedLabelID: String? = SystemLabel.inbox {
        didSet {
            guard selectedLabelID != oldValue else { return }
            // Choosing another mailbox leaves search.
            search.clear()
            selectedThreadIDs = []
            threads = []
            threadLimit = Self.pageSize
            older?.cancel()
            older = nil
            observeThreads()
            if selectedLabelID == SystemLabel.draft {
                // Drafts made in other apps since the last sync.
                let engine = engine
                Task { try? await engine.refreshDrafts() }
            }
        }
    }
    var selectedThreadIDs: Set<String> = []
    var notice: Notice?
    /// The newest send's notice, above `notice` so other actions don't replace it.
    var sendNotice: Notice?
    /// The newest send still inside its undo delay, for Edit > Undo Send.
    private(set) var undoableSendID: String?

    private(set) var threads: [ThreadRecord] = []
    /// Gmail's older pages of the selected mailbox, after Load Older Conversations.
    private(set) var older: GmailPager?

    /// The window's undo manager, so Edit > Undo reverts mail actions.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet {
            guard oldValue !== undoManager else { return }
            for entry in undoEntries.values { oldValue?.removeAllActions(withTarget: entry) }
            undoEntries = [:]
            undoOrder = []
            undoManager?.levelsOfUndo = Self.undoLimit
        }
    }
    @ObservationIgnored private var threadLimit = pageSize
    @ObservationIgnored private var undoEntries: [UUID: UndoEntry] = [:]
    @ObservationIgnored private var undoOrder: [UUID] = []
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var undoSendTimer: Task<Void, Never>?

    /// The retained targets are bounded along with UndoManager's history.
    var retainedUndoCount: Int { undoEntries.count }
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var threadsTask: Task<Void, Never>?
    /// Drafts opened from another app with formatting the editor drops, until their window warns.
    @ObservationIgnored private var droppedFormatting = Set<String>()
    /// A draft Gmail refused, whose window the mailbox window reopens.
    var draftToReopen: String?
    /// Edit Labels, open from its toolbar button while set.
    var labelEdit: LabelEdit?
    /// Move to, open from its toolbar button for these conversations while set.
    var moveTargets: Set<String>?
    /// The New Label or Edit Label sheet.
    var labelEditor: LabelEditorRequest?
    /// The label whose deletion waits for confirmation.
    var labelToDelete: LabelRecord?
    /// Choose Date & Time, open for these conversations while set.
    var snoozeDateTargets: Set<String>?
    /// Open compose windows, so quitting can store what they show.
    @ObservationIgnored private var composeModels = NSHashTable<ComposeModel>.weakObjects()

    /// `outgoingDirectory` holds copies of the files attached to drafts.
    /// `snoozeStore` keeps the durable copy of snoozes; without it the
    /// mailbox can't snooze.
    init(
        account: AccountRecord,
        cache: MailCache,
        gmail: any GmailService,
        outgoingDirectory: URL,
        downloadsDirectory: URL = MailboxModel.defaultDownloadsDirectory,
        snoozeStore: AccountStore? = nil
    ) {
        self.cache = cache
        self.downloadsDirectory = downloadsDirectory
        primary = AccountMailbox(
            account: account, cache: cache, gmail: gmail, outgoingDirectory: outgoingDirectory, snoozeStore: snoozeStore
        )
        search = SearchModel(accountID: account.id, cache: cache, engine: primary.engine)
        search.onResultsChange = { [weak self] in self?.listChanged() }
        primary.onLabelsChange = { [weak self] in self?.labelsChanged() }
        primary.onSnoozedChange = { [weak self] in self?.snoozedChanged() }
        primary.onEvent = { [weak self] in self?.handle($0) }
    }

    func start() async {
        guard !isStopped else { return }
        observeThreads()
        await primary.start()
    }

    /// Returns once the accounts have stopped writing to the cache.
    func stop() async {
        isStopped = true
        threadsTask?.cancel()
        search.stop()
        older?.cancel()
        actionTask?.cancel()
        undoSendTimer?.cancel()
        for entry in undoEntries.values {
            undoManager?.removeAllActions(withTarget: entry)
        }
        undoEntries = [:]
        undoOrder = []
        await primary.stop()
    }

    func syncNow() {
        primary.syncNow()
    }

    // MARK: Reading

    var labels: [LabelRecord] { primary.labels }
    var outbox: [DraftActivity] { primary.outbox }
    var snoozed: [SnoozedThread] { primary.snoozed }
    var wokenThreadIDs: Set<String> { primary.wokenThreadIDs }
    var snoozeKeeper: SnoozeKeeper? { primary.snoozeKeeper }
    var syncStatus: AccountMailbox.SyncStatus { primary.syncStatus }
    var lastSyncedAt: Date? { primary.lastSyncedAt }
    var hasSyncedOnce: Bool { primary.hasSyncedOnce }

    var userLabels: [LabelRecord] {
        labels.filter { !$0.isSystem }
    }

    /// The Outbox stays in the sidebar while it is selected, even once empty.
    var showsOutbox: Bool {
        !outbox.isEmpty || selectedLabelID == Self.outboxID
    }

    func label(id: String) -> LabelRecord? {
        labels.first { $0.id == id }
    }

    /// The conversations the list shows: search results while searching,
    /// otherwise the selected mailbox.
    var listedThreads: [ThreadRecord] {
        search.isActive ? search.results : threads
    }

    var selectedLabelTitle: String {
        if search.isActive { return "Search Results" }
        guard let id = selectedLabelID else { return "Tern" }
        if id == Self.outboxID { return "Outbox" }
        return SystemMailbox.all.first { $0.id == id }?.title ?? label(id: id)?.name ?? "Tern"
    }

    func threadDetail(_ threadID: String) -> AsyncThrowingStream<ThreadDetail?, any Error> {
        cache.thread(accountID: account.id, threadID: threadID)
    }

    /// Loads missing bodies and marks the thread read.
    func open(_ threadID: String) async {
        do {
            try await engine.openThread(threadID)
        } catch {
            // Switching conversations cancels the load, which isn't a failure.
            guard !Task.isCancelled, !(error is CancellationError), !isStopped else { return }
            notice = Notice(message: "Tern couldn't load this conversation. Check your connection.", isError: true)
        }
    }

    /// The attachment's file, downloaded if this is its first open, or nil
    /// after showing why it couldn't be.
    func download(_ attachment: AttachmentRecord) async -> URL? {
        do {
            return try await engine.downloadAttachment(attachment, into: downloadsDirectory)
        } catch {
            guard !isStopped, !(error is CancellationError) else { return nil }
            notice = Notice(message: "Tern couldn't download “\(attachment.filename)”. Check your connection.", isError: true)
            return nil
        }
    }

    func loadMoreThreads() {
        guard threads.count >= threadLimit else { return }
        threadLimit += Self.pageSize
        observeThreads()
    }

    /// Whether the list ends with Load Older Conversations: the cache has
    /// nothing more for this mailbox, and Gmail may. The cache holds all of
    /// the Inbox and Drafts.
    var offersOlderConversations: Bool {
        guard let id = selectedLabelID, ![SystemLabel.inbox, SystemLabel.draft, Self.outboxID, Self.snoozedID].contains(id),
              threads.count < threadLimit
        else { return false }
        return older?.state != .finished
    }

    /// Asks Gmail for the mailbox's next page older than the list, stores it
    /// and shows it at the end of the list.
    func loadOlderConversations() {
        guard let labelID = selectedLabelID, offersOlderConversations else { return }
        if older == nil {
            let engine = engine
            let cutoff = threads.map(\.lastDate).min()
            older = GmailPager { token in try await engine.loadOlder(labelID: labelID, before: cutoff, pageToken: token) }
        }
        older?.next { [weak self] page in
            guard let self, selectedLabelID == labelID else { return }
            threadLimit = max(threadLimit, threads.count + page.count)
            observeThreads()
        }
    }

    // MARK: Compose

    /// Makes the local draft for a compose window and returns its ID, or nil
    /// after showing why it couldn't.
    func startCompose(_ start: ComposeStart) async -> String? {
        guard !isStopped else { return nil }
        do {
            switch start {
            case .newMessage:
                return try await engine.startMessage().id
            case .reply(let kind, let messageID):
                return try await engine.startReply(kind, to: messageID).id
            case .editDraft(let messageID):
                let opened = try await engine.openDraft(messageID: messageID)
                if opened.droppedFormatting { droppedFormatting.insert(opened.draft.id) }
                return opened.draft.id
            }
        } catch {
            guard !isStopped, !(error is CancellationError) else { return nil }
            let message = (error as? ComposeError)?.errorDescription ?? Self.composeFailure(start)
            notice = Notice(message: message, isError: true)
            return nil
        }
    }

    /// Reply and Forward in the menu bar answer one selected conversation.
    var canReply: Bool { selectedThreadIDs.count == 1 }

    /// The newest message in the selected conversation that isn't a draft.
    func replyTargetMessageID() async -> String? {
        guard canReply, let threadID = selectedThreadIDs.first else { return nil }
        do {
            for try await detail in cache.thread(accountID: account.id, threadID: threadID) {
                return detail?.messages.last { !$0.labels.contains(SystemLabel.draft) }?.id
            }
        } catch {
            notice = Notice(message: "Tern couldn't read this conversation.", isError: true)
        }
        return nil
    }

    /// Whether the draft's window should warn about formatting it can't keep. Asked once.
    func takeDroppedFormatting(_ localDraftID: String) -> Bool {
        droppedFormatting.remove(localDraftID) != nil
    }

    /// Shows the send's notice with Undo Send for as long as the send waits.
    func didQueueSend(_ localDraftID: String, delay: TimeInterval) {
        sendNotice = Notice(message: "Sending message", undo: .send(localDraftID: localDraftID), duration: .seconds(delay))
        undoableSendID = localDraftID
        undoSendTimer?.cancel()
        undoSendTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self?.undoableSendID == localDraftID else { return }
            self?.undoableSendID = nil
        }
    }

    func composeOpened(_ model: ComposeModel) {
        composeModels.add(model)
    }

    /// Stores the drafts of open compose windows before the app quits.
    func prepareToQuit() async {
        for model in composeModels.allObjects {
            await model.prepareToQuit()
        }
    }

    func didQueueDiscard(_ localDraftID: String, hold: TimeInterval) {
        notice = Notice(message: "Draft discarded", undo: .discard(localDraftID: localDraftID), duration: .seconds(hold))
    }

    /// Puts a waiting send back to editing. True means the caller reopens its window.
    func undoSend(_ localDraftID: String) async -> Bool {
        do {
            let undone = try await engine.undoSend(localDraftID)
            guard !isStopped else { return false }
            finishSend(localDraftID)
            if undone {
                // The reopened window is the visible sign, which VoiceOver doesn't read out.
                AccessibilityNotification.Announcement("Send undone").post()
            } else {
                sendNotice = Notice(message: "Too late to undo. Tern has started sending this message.")
            }
            return undone
        } catch {
            guard !isStopped else { return false }
            sendNotice = Notice(message: "Tern couldn't stop this message.", isError: true)
            return false
        }
    }

    /// Keeps a discarded draft. True means the caller reopens its window.
    func undoDiscard(_ localDraftID: String) async -> Bool {
        do {
            let undone = try await engine.undoDiscard(localDraftID)
            guard !isStopped else { return false }
            if !undone {
                notice = Notice(message: "Too late to undo. Tern has already discarded this draft.")
            } else if notice?.undo == .discard(localDraftID: localDraftID) {
                notice = nil
            }
            return undone
        } catch {
            guard !isStopped else { return false }
            notice = Notice(message: "Tern couldn't keep this draft.", isError: true)
            return false
        }
    }

    private static func composeFailure(_ start: ComposeStart) -> String {
        switch start {
        case .newMessage: "Tern couldn't start a new message."
        case .reply(.forward, _): "Tern couldn't load the message to forward. Check your connection."
        case .reply: "Tern couldn't load the message to reply to. Check your connection."
        case .editDraft: "Tern couldn't open this draft. Check your connection."
        }
    }

    // MARK: Actions

    @discardableResult
    func perform(_ action: MailAction, on threadIDs: Set<String>? = nil) -> Task<Void, Never>? {
        let ids = Array(threadIDs ?? selectedThreadIDs)
        guard !ids.isEmpty, !isStopped else { return nil }
        // Search results follow Gmail's labels, so they change after the next sync pass.
        if !search.isActive,
           (action == .archive && selectedLabelID == SystemLabel.inbox)
            || (action == .trash && selectedLabelID != SystemLabel.trash) {
            selectThread(after: Set(ids))
        }
        return queueUndoable(Self.undoName(action), confirmation: Self.confirmation(action, count: ids.count)) { engine in
            try await engine.perform(action, threadIDs: ids)
        }
    }

    /// Queues a change with Undo, in order after earlier changes. The undo
    /// entry is registered inside the initiating event, so it can remember
    /// an undo requested before the engine returns the durable queue rows.
    /// `confirmation` shows in a notice with Undo. `revert` replaces the
    /// engine's undo for changes that keep more than queue rows.
    @discardableResult
    func queueUndoable(
        _ name: String,
        confirmation: String? = nil,
        revert: (@Sendable (ActionReceipt) async throws -> Void)? = nil,
        _ change: @escaping @Sendable (SyncEngine) async throws -> ActionReceipt?
    ) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        let entry = UndoEntry(name: name, revert: revert)
        registerUndo(entry)
        let previous = actionTask
        let engine = engine
        let task = Task {
            await previous?.value
            guard !isStopped, !Task.isCancelled else { return }
            do {
                guard let row = try await change(engine) else {
                    removeUndo(entry)
                    return
                }
                guard !isStopped else { return }
                entry.receipt = row
                if entry.undoRequested {
                    await requestUndo(entry)?.value
                } else if let confirmation {
                    notice = Notice(message: confirmation, undo: .action(row))
                }
            } catch {
                removeUndo(entry)
                guard !isStopped else { return }
                notice = Notice(message: Self.failureMessage(error), isError: true)
            }
        }
        actionTask = task
        return task
    }

    /// Reverts an action, from the notice or Edit > Undo.
    func undo(_ row: ActionReceipt) {
        let entry = undoEntries.values.first { $0.receipt?.id == row.id } ?? UndoEntry(name: "Change")
        entry.receipt = row
        _ = requestUndo(entry)
    }

    private func requestUndo(_ entry: UndoEntry) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        entry.undoRequested = true
        if !((undoManager?.isUndoing) ?? false) { undoManager?.removeAllActions(withTarget: entry) }
        guard let row = entry.receipt, !entry.isApplying else { return nil }
        entry.isApplying = true
        let engine = engine
        let revert = entry.revert
        return Task {
            do {
                if let revert {
                    try await revert(row)
                } else {
                    try await engine.undo(row)
                }
                removeUndo(entry)
                if notice?.undo == .action(row) { notice = nil }
            } catch {
                guard !isStopped else { return }
                entry.isApplying = false
                entry.undoRequested = false
                registerUndo(entry)
                notice = Notice(message: "Tern couldn't undo that change. Try again.", undo: .action(row), isError: true)
            }
        }
    }

    /// True when every thread in `ids` is read, so commands offer Mark as Unread.
    func allRead(_ ids: Set<String>) -> Bool {
        !listedThreads.contains { ids.contains($0.id) && $0.isUnread }
    }

    func allStarred(_ ids: Set<String>) -> Bool {
        let matching = listedThreads.filter { ids.contains($0.id) }
        return !matching.isEmpty && matching.allSatisfy(\.isStarred)
    }

    func toggleRead(_ ids: Set<String>? = nil) {
        let ids = ids ?? selectedThreadIDs
        perform(allRead(ids) ? .markUnread : .markRead, on: ids)
    }

    func toggleStar(_ ids: Set<String>? = nil) {
        let ids = ids ?? selectedThreadIDs
        perform(allStarred(ids) ? .unstar : .star, on: ids)
    }

    /// Archiving from Trash or Spam would leave the thread there, so it is
    /// offered elsewhere only. Search results come from any mailbox.
    var offersArchive: Bool {
        search.isActive || (selectedLabelID != SystemLabel.trash && selectedLabelID != SystemLabel.spam)
    }

    var offersTrash: Bool {
        search.isActive || selectedLabelID != SystemLabel.trash
    }

    var canArchive: Bool {
        !selectedThreadIDs.isEmpty && offersArchive
    }

    var canTrash: Bool {
        !selectedThreadIDs.isEmpty && offersTrash
    }

    // MARK: Private

    private func observeThreads() {
        threadsTask?.cancel()
        guard let labelID = selectedLabelID, labelID != Self.outboxID else {
            threads = []
            return
        }
        if labelID == Self.snoozedID {
            // The snoozed stream fills it.
            threads = snoozed.map(\.thread)
            listChanged()
            return
        }
        let stream = cache.threads(accountID: account.id, labelID: labelID, limit: threadLimit)
        threadsTask = Task { [weak self] in
            do {
                for try await threads in stream {
                    guard let self, !Task.isCancelled, !isStopped, selectedLabelID == labelID else { return }
                    self.threads = threads
                    listChanged()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.primary.cacheReadFailed()
            }
        }
    }

    /// Leaves a label that's gone for the Inbox.
    private func labelsChanged() {
        guard !isStopped, let id = selectedLabelID, id != Self.outboxID,
              !SystemMailbox.all.contains(where: { $0.id == id }),
              !labels.contains(where: { $0.id == id })
        else { return }
        selectedLabelID = SystemLabel.inbox
    }

    private func snoozedChanged() {
        guard !isStopped, selectedLabelID == Self.snoozedID else { return }
        threads = snoozed.map(\.thread)
        listChanged()
    }

    /// Keeps the selection inside the list, and tells the engine what the
    /// list shows so expired search holds don't drop it.
    private func listChanged() {
        let ids = listedThreads.map(\.id)
        selectedThreadIDs.formIntersection(ids)
        engine.setVisibleThreads(Set(ids))
    }

    /// Shows the engine events the account passes on.
    private func handle(_ event: SyncEvent) {
        guard !isStopped else { return }
        switch event {
        case .syncStarted, .syncFinished, .syncFailed:
            break
        case .actionFailed(let message):
            notice = Notice(message: message, isError: true)
        case .draftFailed(let id, let message):
            finishSend(id)
            notice = Notice(message: message, isError: true)
            // The window shows Gmail's message and lets the person fix the draft.
            draftToReopen = id
        case .draftCopied:
            notice = Notice(message: "Another app changed this draft, so Tern kept both versions.")
        case .draftSent(let id):
            finishSend(id)
            // A newer send keeps its notice and its Undo Send.
            if case .send = sendNotice?.undo { return }
            sendNotice = Notice(message: "Message sent")
        }
    }

    /// Ends the draft's undo window and removes its notice.
    private func finishSend(_ localDraftID: String) {
        if undoableSendID == localDraftID { undoableSendID = nil }
        if sendNotice?.undo == .send(localDraftID: localDraftID) { sendNotice = nil }
    }

    /// Moves the selection to the thread below the ones leaving the list, or above if none is below.
    func selectThread(after leaving: Set<String>) {
        let threads = listedThreads
        guard leaving == selectedThreadIDs,
              let lastIndex = threads.lastIndex(where: { leaving.contains($0.id) })
        else { return }
        let below = threads[(lastIndex + 1)...].first { !leaving.contains($0.id) }
        let above = threads[..<lastIndex].last { !leaving.contains($0.id) }
        selectedThreadIDs = (below ?? above).map { [$0.id] } ?? []
    }

    private func registerUndo(_ entry: UndoEntry) {
        undoEntries[entry.id] = entry
        undoOrder.removeAll { $0 == entry.id }
        undoOrder.append(entry.id)
        while undoOrder.count > Self.undoLimit {
            let oldest = undoOrder.removeFirst()
            if let discarded = undoEntries.removeValue(forKey: oldest) {
                undoManager?.removeAllActions(withTarget: discarded)
            }
        }
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: entry) { [weak self] entry in
            // The window's undo manager runs its handlers on the main thread.
            MainActor.assumeIsolated { _ = self?.requestUndo(entry) }
        }
        undoManager.setActionName(entry.name)
        undoManager.endUndoGrouping()
    }

    private func removeUndo(_ entry: UndoEntry) {
        undoEntries.removeValue(forKey: entry.id)
        undoOrder.removeAll { $0 == entry.id }
        if !((undoManager?.isUndoing) ?? false) { undoManager?.removeAllActions(withTarget: entry) }
    }

    private static func undoName(_ action: MailAction) -> String {
        switch action {
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .markRead: "Mark as Read"
        case .markUnread: "Mark as Unread"
        case .star: "Star"
        case .unstar: "Remove Star"
        }
    }

    /// Archive and trash move threads out of sight, so they confirm with Undo.
    private static func confirmation(_ action: MailAction, count: Int) -> String? {
        let subject = count == 1 ? "Conversation" : "\(count) conversations"
        switch action {
        case .archive: return "\(subject) archived"
        case .trash: return "\(subject) moved to Trash"
        case .markRead, .markUnread, .star, .unstar: return nil
        }
    }
}

/// The target of one Edit > Undo entry. The model keeps it alive until the
/// entry is used or removed.
@MainActor
private final class UndoEntry {
    let id = UUID()
    let name: String
    /// Undoes the change instead of the engine. Nil uses the engine.
    let revert: (@Sendable (ActionReceipt) async throws -> Void)?
    var receipt: ActionReceipt?
    var undoRequested = false
    var isApplying = false

    init(name: String, revert: (@Sendable (ActionReceipt) async throws -> Void)? = nil) {
        self.name = name
        self.revert = revert
    }
}

/// The sidebar's mailboxes in order: Gmail's system labels and Tern's Snoozed.
struct SystemMailbox: Identifiable {
    let id: String
    let title: String
    let systemImage: String

    static let all = [
        SystemMailbox(id: SystemLabel.inbox, title: "Inbox", systemImage: "tray"),
        SystemMailbox(id: SystemLabel.starred, title: "Starred", systemImage: "star"),
        SystemMailbox(id: MailboxModel.snoozedID, title: "Snoozed", systemImage: "clock"),
        SystemMailbox(id: SystemLabel.sent, title: "Sent", systemImage: "paperplane"),
        SystemMailbox(id: SystemLabel.draft, title: "Drafts", systemImage: "doc"),
        SystemMailbox(id: SystemLabel.allMail, title: "All Mail", systemImage: "archivebox"),
        SystemMailbox(id: SystemLabel.spam, title: "Spam", systemImage: "xmark.bin"),
        SystemMailbox(id: SystemLabel.trash, title: "Trash", systemImage: "trash"),
    ]
}
