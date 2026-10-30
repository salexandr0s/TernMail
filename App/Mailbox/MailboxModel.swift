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
    nonisolated static let outboxID = "TERN_OUTBOX"
    /// The sidebar's Snoozed, which Tern keeps itself since Gmail's API has none.
    nonisolated static let snoozedID = "TERN_SNOOZED"
    /// Received attachments, downloaded when opened. Signing out deletes them.
    static let defaultDownloadsDirectory = URL.cachesDirectory.appending(path: "Tern/Attachments", directoryHint: .isDirectory)

    /// Where a compose window's draft comes from. Replies and Gmail drafts
    /// stay in their message's account.
    enum ComposeStart: Equatable {
        /// A new message from `composeAccount`.
        case newMessage
        case reply(ReplyKind, messageID: String, accountID: String)
        /// A Gmail draft shown in a thread.
        case editDraft(messageID: String, accountID: String)
    }

    /// The first signed-in account. New messages from a combined mailbox use it.
    private(set) var defaultAccount: AccountMailbox
    /// The accounts added after the first.
    private(set) var otherAccounts: [AccountMailbox] = []
    /// Compose windows read and edit their drafts through these directly.
    let cache: MailCache
    var engine: SyncEngine { defaultAccount.engine }
    var account: AccountRecord { defaultAccount.account }
    let downloadsDirectory: URL
    @ObservationIgnored private let outgoingDirectory: URL
    @ObservationIgnored private let snoozeStore: AccountStore?
    @ObservationIgnored private var isStarted = false
    /// While the search field has text, the list shows its results.
    let search: SearchModel

    /// The mailbox the sidebar has selected.
    var selectedMailbox: MailboxID? {
        didSet {
            guard selectedMailbox != oldValue else { return }
            // Choosing another mailbox leaves search.
            search.clear()
            updateSearchSources()
            selectedThreadIDs = []
            threads = []
            threadLimit = Self.pageSize
            older?.cancel()
            older = nil
            observeThreads()
            if selectedLabelID == SystemLabel.draft {
                // Drafts made in other apps since the last sync.
                for engine in selectedAccounts.map(\.engine) {
                    Task { try? await engine.refreshDrafts() }
                }
            }
        }
    }
    /// The selected mailbox's label or virtual mailbox ID, whichever account it's in.
    var selectedLabelID: String? { selectedMailbox?.id }
    var selectedThreadIDs: Set<ThreadKey> = []
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
    var moveTargets: Set<ThreadKey>?
    /// The New Label or Edit Label sheet.
    var labelEditor: LabelEditorRequest?
    /// The label whose deletion waits for confirmation.
    var labelToDelete: LabelRecord?
    /// Choose Date & Time, open for these conversations while set.
    var snoozeDateTargets: Set<ThreadKey>?
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
        self.outgoingDirectory = outgoingDirectory
        self.snoozeStore = snoozeStore
        selectedMailbox = .account(account.id, SystemLabel.inbox)
        let first = AccountMailbox(
            account: account, cache: cache, gmail: gmail, outgoingDirectory: outgoingDirectory, snoozeStore: snoozeStore
        )
        defaultAccount = first
        search = SearchModel(cache: cache, sources: [.init(accountID: account.id, engine: first.engine)])
        search.onResultsChange = { [weak self] in self?.listChanged() }
        wire(first)
    }

    /// Every signed-in account, the default one first.
    var accounts: [AccountMailbox] { [defaultAccount] + otherAccounts }

    private func isSignedIn(_ owner: AccountMailbox) -> Bool {
        accounts.contains { $0 === owner }
    }

    func account(id: String) -> AccountMailbox? {
        accounts.first { $0.account.id == id }
    }

    /// Adds a signed-in account, starting it if the mailbox has started.
    func addAccount(_ account: AccountRecord, gmail: any GmailService) async {
        guard !isStopped, self.account(id: account.id) == nil else { return }
        let added = AccountMailbox(
            account: account, cache: cache, gmail: gmail, outgoingDirectory: outgoingDirectory, snoozeStore: snoozeStore
        )
        wire(added)
        otherAccounts.append(added)
        accountsChanged()
        if isStarted { await added.start() }
    }

    /// Takes an account out of the window and stops it, for its sign-out.
    /// The next account becomes the default if this one was. Returns once
    /// the account no longer writes to the cache.
    func removeAccount(id: String) async {
        guard hasSeveralAccounts, let removed = account(id: id) else { return }
        if removed === defaultAccount {
            defaultAccount = otherAccounts.removeFirst()
        } else {
            otherAccounts.removeAll { $0 === removed }
        }
        removed.onLabelsChange = nil
        removed.onSnoozedChange = nil
        removed.onEvent = nil
        // Undo, pickers and sheets can't reach a signed-out account. Undo
        // keeps the other accounts' part of a command.
        for entry in undoEntries.values {
            entry.applied.removeAll { $0.account === removed }
            guard entry.applied.isEmpty, !entry.isQueued else { continue }
            removeUndo(entry)
            if let handle = entry.handle, notice?.undo == .action(handle) { notice = nil }
        }
        if labelEdit?.accountID == id { labelEdit = nil }
        if labelEditor?.accountID == id { labelEditor = nil }
        if labelToDelete?.accountID == id { labelToDelete = nil }
        if moveTargets?.contains(where: { $0.accountID == id }) == true { moveTargets = nil }
        if snoozeDateTargets?.contains(where: { $0.accountID == id }) == true { snoozeDateTargets = nil }
        switch selectedMailbox {
        case .account(id, _)?:
            selectedMailbox = .account(defaultAccount.account.id, SystemLabel.inbox)
        case .combined(let box)? where !hasSeveralAccounts && box != AttachmentLibraryModel.mailboxID:
            selectedMailbox = .account(defaultAccount.account.id, box)
        default:
            selectedThreadIDs = selectedThreadIDs.filter { $0.accountID != id }
        }
        // Search and combined lists drop it before it stops.
        accountsChanged()
        await removed.stop()
        // Its drafts' notices and Undo Send. Their rows stay until the
        // account's data is deleted, after this returns.
        let draftIDs = [undoableSendID, draftToReopen, Self.draftID(in: notice), Self.draftID(in: sendNotice)]
        for draftID in await drafts(draftIDs.compactMap { $0 }, in: id) {
            finishSend(draftID)
            if Self.draftID(in: notice) == draftID { notice = nil }
            if draftToReopen == draftID { draftToReopen = nil }
        }
    }

    private static func draftID(in notice: Notice?) -> String? {
        switch notice?.undo {
        case .send(let id)?, .discard(let id)?: id
        case .action?, nil: nil
        }
    }

    /// Which of `ids` are local drafts of `accountID`.
    private func drafts(_ ids: [String], in accountID: String) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let found = try? await cache.read { tx in
            try ids.filter { try tx.localDraft(id: $0)?.accountID == accountID }
        }
        return Set(found ?? [])
    }

    func start() async {
        guard !isStopped, !isStarted else { return }
        isStarted = true
        observeThreads()
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await account.start() }
            }
        }
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
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await account.stop() }
            }
        }
    }

    func syncNow() {
        accounts.forEach { $0.syncNow() }
    }

    // MARK: Reading

    /// The account label commands and Load Older act in: the selected
    /// mailbox's, or in a combined mailbox the selected conversations'
    /// when they share one, otherwise the default account.
    var currentAccount: AccountMailbox {
        if case .account(let accountID, _)? = selectedMailbox, let owner = account(id: accountID) { return owner }
        let owners = Set(selectedThreadIDs.map(\.accountID))
        if owners.count == 1, let accountID = owners.first, let owner = account(id: accountID) { return owner }
        return defaultAccount
    }

    var labels: [LabelRecord] { currentAccount.labels }
    var outbox: [DraftActivity] { accounts.flatMap(\.outbox) }
    /// Every account's snoozed conversations, the soonest to wake first.
    var snoozed: [SnoozedThread] { accounts.flatMap(\.snoozed).sorted { $0.wakeAt < $1.wakeAt } }
    var snoozeKeeper: SnoozeKeeper? { currentAccount.snoozeKeeper }
    /// A failure in any account first, then syncing if any account is.
    var syncStatus: AccountMailbox.SyncStatus { Self.syncStatus(of: accounts) }
    /// The same for the accounts the selected mailbox lists, for its empty state.
    var selectedSyncStatus: AccountMailbox.SyncStatus { Self.syncStatus(of: selectedAccounts) }
    /// The oldest of the accounts' last syncs.
    var lastSyncedAt: Date? {
        let dates = accounts.map(\.lastSyncedAt)
        return dates.contains(nil) ? nil : dates.compactMap { $0 }.min()
    }
    var hasSyncedOnce: Bool { accounts.allSatisfy(\.hasSyncedOnce) }
    var selectedHaveSyncedOnce: Bool { selectedAccounts.allSatisfy(\.hasSyncedOnce) }

    private static func syncStatus(of accounts: [AccountMailbox]) -> AccountMailbox.SyncStatus {
        let statuses = accounts.map(\.syncStatus)
        if let failed = statuses.first(where: { if case .failed = $0 { true } else { false } }) { return failed }
        return statuses.contains(.syncing) ? .syncing : .idle
    }

    var userLabels: [LabelRecord] {
        labels.filter { !$0.isSystem }
    }

    /// The Outbox of the selected mailbox's accounts.
    var selectedOutbox: [DraftActivity] { selectedAccounts.flatMap(\.outbox) }

    /// With more than one account each sidebar mailbox lists every account's
    /// mail and expands to one row per account.
    var hasSeveralAccounts: Bool { !otherAccounts.isEmpty }

    /// Whether the list can show conversations from more than one account,
    /// so each row names its account.
    var listMixesAccounts: Bool {
        searchedAccounts.count > 1
    }

    /// The accounts search covers: the one in view, or every account in a
    /// combined mailbox or while no mailbox is selected. The list shows the
    /// same accounts when a mailbox is selected.
    private var searchedAccounts: [AccountMailbox] {
        selectedMailbox.map(owners(of:)) ?? accounts
    }

    /// The account under the list's title when there are several.
    var selectedMailboxSubtitle: String {
        guard hasSeveralAccounts, !search.isActive, let selectedMailbox else { return "" }
        if case .account(let accountID, _) = selectedMailbox { return account(id: accountID)?.account.email ?? "" }
        return "All Accounts"
    }

    /// A sidebar Outbox shows while it has items, and while it is selected.
    func showsOutbox(_ box: MailboxID) -> Bool {
        selectedMailbox == box || !outbox(in: box).isEmpty
    }

    func outbox(in box: MailboxID) -> [DraftActivity] {
        owners(of: box).flatMap(\.outbox)
    }

    /// A sidebar mailbox's unread conversations, summed across accounts
    /// for a combined one.
    func unreadCount(_ box: MailboxID) -> Int {
        owners(of: box).reduce(0) { total, owner in
            total + (owner.labels.first { $0.id == box.id }?.threadsUnread ?? 0)
        }
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

    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ThreadDetail?, any Error> {
        cache.thread(accountID: key.accountID, threadID: key.threadID)
    }

    /// Loads missing bodies and marks the thread read.
    func open(_ key: ThreadKey) async -> Bool {
        guard let owner = account(id: key.accountID) else { return false }
        do {
            try await owner.engine.openThread(key.threadID)
            return true
        } catch {
            // Switching conversations cancels the load, which isn't a failure.
            guard !Task.isCancelled, !(error is CancellationError), !isStopped else { return false }
            notice = Notice(message: "Couldn't load this conversation. Try again.", isError: true)
            return false
        }
    }

    /// The attachment's file, downloaded if this is its first open, or nil
    /// after showing why it couldn't be.
    func download(_ attachment: AttachmentRecord) async -> URL? {
        do {
            guard let owner = account(id: attachment.accountID) else { return nil }
            // Message IDs repeat across accounts, so each account has its own folder.
            let folder = downloadsDirectory.appending(path: attachment.accountID, directoryHint: .isDirectory)
            return try await owner.engine.downloadAttachment(attachment, into: folder)
        } catch {
            guard !isStopped, !(error is CancellationError) else { return nil }
            notice = Notice(message: "Couldn't download “\(attachment.filename)”. Try again.", isError: true)
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
        // Gmail pages one account at a time.
        guard case .account(_, let id)? = selectedMailbox,
              ![SystemLabel.inbox, SystemLabel.draft, Self.outboxID, Self.snoozedID].contains(id),
              threads.count < threadLimit
        else { return false }
        return older?.state != .finished
    }

    /// Asks Gmail for the mailbox's next page older than the list, stores it
    /// and shows it at the end of the list.
    func loadOlderConversations() {
        guard case .account(let accountID, let labelID)? = selectedMailbox, offersOlderConversations,
              let engine = self.account(id: accountID)?.engine
        else { return }
        let mailbox = selectedMailbox
        if older == nil {
            let cutoff = threads.map(\.lastDate).min()
            older = GmailPager(accountID: accountID) { token in
                try await engine.loadOlder(labelID: labelID, before: cutoff, pageToken: token)
            }
        }
        older?.next { [weak self] page in
            guard let self, selectedMailbox == mailbox else { return }
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
                return try await composeAccount.engine.startMessage().id
            case .reply(let kind, let messageID, let accountID):
                guard let owner = account(id: accountID) else { return nil }
                return try await owner.engine.startReply(kind, to: messageID).id
            case .editDraft(let messageID, let accountID):
                guard let owner = account(id: accountID) else { return nil }
                let opened = try await owner.engine.openDraft(messageID: messageID)
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

    /// The account a new message starts in: the selected mailbox's, or the
    /// default account in a combined mailbox.
    var composeAccount: AccountMailbox {
        if case .account(let accountID, _)? = selectedMailbox, let owner = account(id: accountID) { return owner }
        return defaultAccount
    }

    /// The Go menu: a system mailbox across accounts, as the sidebar's top row
    /// for it lists them, so ⌘1 to ⌘5 match the sidebar's first rows.
    func go(to labelID: String) {
        search.clear()
        if hasSeveralAccounts, SystemMailbox.all.contains(where: { $0.id == labelID }) {
            selectedMailbox = .combined(labelID)
        } else {
            let accountID = if case .account(let id, _)? = selectedMailbox { id } else { defaultAccount.account.id }
            selectedMailbox = .account(accountID, labelID)
        }
    }

    /// Reply and Forward in the menu bar answer one selected conversation.
    var canReply: Bool { selectedThreadIDs.count == 1 }

    /// A reply to the newest message in the selected conversation that isn't a draft.
    func replyStart(_ kind: ReplyKind) async -> ComposeStart? {
        guard canReply, let key = selectedThreadIDs.first else { return nil }
        do {
            for try await detail in cache.thread(accountID: key.accountID, threadID: key.threadID) {
                let target = detail?.messages.last { !$0.labels.contains(SystemLabel.draft) }
                return target.map { .reply(kind, messageID: $0.id, accountID: key.accountID) }
            }
        } catch {
            notice = Notice(message: "Couldn't read this conversation. Try again.", isError: true)
        }
        return nil
    }

    /// Whether the draft's window should warn about formatting it can't keep. Asked once.
    func takeDroppedFormatting(_ localDraftID: String) -> Bool {
        droppedFormatting.remove(localDraftID) != nil
    }

    /// Shows the send's notice with Undo Send for as long as the send waits.
    func didQueueSend(_ localDraftID: String, delay: TimeInterval) {
        sendNotice = Notice(message: "Message queued", undo: .send(localDraftID: localDraftID), duration: .seconds(delay))
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
            guard let owner = try await owner(ofDraft: localDraftID) else { return false }
            let undone = try await owner.engine.undoSend(localDraftID)
            guard !isStopped else { return false }
            finishSend(localDraftID)
            if undone {
                // The reopened window is the visible sign, which VoiceOver doesn't read out.
                AccessibilityNotification.Announcement("Send undone").post()
            } else {
                sendNotice = Notice(message: "Sending has started. Undo is no longer available.")
            }
            return undone
        } catch {
            guard !isStopped else { return false }
            sendNotice = Notice(message: "Couldn't undo sending.", isError: true)
            return false
        }
    }

    /// Keeps a discarded draft. True means the caller reopens its window.
    func undoDiscard(_ localDraftID: String) async -> Bool {
        do {
            guard let owner = try await owner(ofDraft: localDraftID) else { return false }
            let undone = try await owner.engine.undoDiscard(localDraftID)
            guard !isStopped else { return false }
            if !undone {
                notice = Notice(message: "Draft already discarded. Undo is no longer available.")
            } else if notice?.undo == .discard(localDraftID: localDraftID) {
                notice = nil
            }
            return undone
        } catch {
            guard !isStopped else { return false }
            notice = Notice(message: "Couldn't restore this draft.", isError: true)
            return false
        }
    }

    /// The account a local draft belongs to. Draft IDs are unique across accounts.
    private func owner(ofDraft localDraftID: String) async throws -> AccountMailbox? {
        let accountID = try await cache.read { tx in try tx.localDraft(id: localDraftID)?.accountID }
        return accountID.flatMap { account(id: $0) }
    }

    private static func composeFailure(_ start: ComposeStart) -> String {
        switch start {
        case .newMessage: "Couldn't start a new message. Try again."
        case .reply(.forward, _, _): "Couldn't prepare the forwarded message. Try again."
        case .reply: "Couldn't prepare this reply. Try again."
        case .editDraft: "Couldn't open this draft. Try again."
        }
    }

    // MARK: Actions

    @discardableResult
    func perform(_ action: MailAction, on keys: Set<ThreadKey>? = nil) -> Task<Void, Never>? {
        let keys = keys ?? selectedThreadIDs
        guard !keys.isEmpty, !isStopped else { return nil }
        // Search results follow Gmail's labels, so they change after the next sync pass.
        if !search.isActive,
           (action == .archive && selectedLabelID == SystemLabel.inbox)
            || (action == .trash && selectedLabelID != SystemLabel.trash) {
            selectThread(after: keys)
        }
        return queueUndoable(Self.undoName(action), confirmation: Self.confirmation(action, count: keys.count), for: keys) {
            owner, ids in try await owner.engine.perform(action, threadIDs: ids)
        }
    }

    /// Undoes one account's change instead of its engine, for changes that
    /// keep more than queue rows.
    typealias Revert = @MainActor (AccountMailbox, ActionReceipt) async throws -> Void

    /// Queues a command on conversations in each account they belong to,
    /// with one Undo. `change` gets each account and its thread IDs.
    @discardableResult
    func queueUndoable(
        _ name: String,
        confirmation: String? = nil,
        for keys: Set<ThreadKey>,
        revert: Revert? = nil,
        _ change: @escaping @MainActor (AccountMailbox, [String]) async throws -> ActionReceipt?
    ) -> Task<Void, Never>? {
        let groups = Dictionary(grouping: keys, by: \.accountID).sorted { $0.key < $1.key }
        let steps: [UndoStep] = groups.compactMap { accountID, keys in
            guard let owner = account(id: accountID) else { return nil }
            let ids = Self.threadIDs(Set(keys))
            return UndoStep(account: owner) { try await change(owner, ids) }
        }
        return queueUndoable(name, confirmation: confirmation, steps: steps, revert: revert)
    }

    /// Queues a command in one account, such as a label change, with Undo.
    @discardableResult
    func queueUndoable(
        _ name: String,
        confirmation: String? = nil,
        in owner: AccountMailbox,
        revert: Revert? = nil,
        _ change: @escaping @MainActor (SyncEngine) async throws -> ActionReceipt?
    ) -> Task<Void, Never>? {
        let step = UndoStep(account: owner) { try await change(owner.engine) }
        return queueUndoable(name, confirmation: confirmation, steps: [step], revert: revert)
    }

    /// Queues the steps with Undo, in order after earlier commands. The undo
    /// entry is registered inside the initiating event, so it can remember
    /// an undo requested before the engines return the durable queue rows.
    /// `confirmation` shows in a notice with Undo.
    private func queueUndoable(_ name: String, confirmation: String?, steps: [UndoStep], revert: Revert?) -> Task<Void, Never>? {
        guard !isStopped, !steps.isEmpty else { return nil }
        let entry = UndoEntry(name: name, revert: revert)
        registerUndo(entry)
        let previous = actionTask
        let task = Task {
            defer { entry.isQueued = false }
            await previous?.value
            guard !isStopped, !Task.isCancelled else { return }
            var failure: (any Error)?
            // An account signed out meanwhile is skipped, and so is its change.
            for step in steps where isSignedIn(step.account) {
                do {
                    if let row = try await step.run(), isSignedIn(step.account) {
                        entry.applied.append(.init(account: step.account, receipt: row))
                        if entry.handle == nil { entry.handle = row }
                    }
                } catch {
                    failure = error
                    break
                }
                guard !isStopped else { return }
            }
            guard let handle = entry.handle else {
                removeUndo(entry)
                if let failure { notice = Notice(message: Self.failureMessage(failure), isError: true) }
                return
            }
            if entry.undoRequested {
                await requestUndo(entry)?.value
            } else if let failure {
                // Undo still takes back the accounts that did change.
                notice = Notice(message: Self.failureMessage(failure), undo: .action(handle), isError: true)
            } else if let confirmation {
                notice = Notice(message: confirmation, undo: .action(handle))
            }
        }
        actionTask = task
        return task
    }

    /// Reverts an action, from the notice or Edit > Undo.
    func undo(_ row: ActionReceipt) {
        if let entry = undoEntries.values.first(where: { $0.handle === row }) {
            _ = requestUndo(entry)
            return
        }
        // Older than the undo history: the receipt still names its account.
        guard let owner = row.actions.first.flatMap({ account(id: $0.accountID) }) else { return }
        let entry = UndoEntry(name: "Change")
        entry.applied = [.init(account: owner, receipt: row)]
        entry.handle = row
        _ = requestUndo(entry)
    }

    private func requestUndo(_ entry: UndoEntry) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        entry.undoRequested = true
        if !((undoManager?.isUndoing) ?? false) { undoManager?.removeAllActions(withTarget: entry) }
        guard let handle = entry.handle, !entry.isApplying else { return nil }
        entry.isApplying = true
        let revert = entry.revert
        return Task {
            do {
                // Newest first. A change undone drops out, so a retry skips
                // it. Signing out of an account drops its changes meanwhile.
                while let last = entry.applied.last {
                    if let revert {
                        try await revert(last.account, last.receipt)
                    } else {
                        try await last.account.engine.undo(last.receipt)
                    }
                    entry.applied.removeAll { $0.receipt === last.receipt }
                }
                removeUndo(entry)
                if notice?.undo == .action(handle) { notice = nil }
            } catch {
                guard !isStopped else { return }
                entry.isApplying = false
                entry.undoRequested = false
                registerUndo(entry)
                notice = Notice(message: "Couldn't undo this change. Try again.", undo: .action(handle), isError: true)
            }
        }
    }

    /// True when every thread in `ids` is read, so commands offer Mark as Unread.
    func allRead(_ keys: Set<ThreadKey>) -> Bool {
        !listedThreads.contains { keys.contains($0.key) && $0.isUnread }
    }

    func allStarred(_ keys: Set<ThreadKey>) -> Bool {
        let matching = listedThreads.filter { keys.contains($0.key) }
        return !matching.isEmpty && matching.allSatisfy(\.isStarred)
    }

    func toggleRead(_ keys: Set<ThreadKey>? = nil) {
        let keys = keys ?? selectedThreadIDs
        perform(allRead(keys) ? .markUnread : .markRead, on: keys)
    }

    func toggleStar(_ keys: Set<ThreadKey>? = nil) {
        let keys = keys ?? selectedThreadIDs
        perform(allStarred(keys) ? .unstar : .star, on: keys)
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
        let sources = selectedAccounts.map(\.account.id)
        guard let mailbox = selectedMailbox, mailbox.id != Self.outboxID, !sources.isEmpty else {
            threads = []
            return
        }
        if mailbox.id == Self.snoozedID {
            // The snoozed streams fill it.
            threads = snoozedThreads()
            listChanged()
            return
        }
        let stream = cache.threads(accountIDs: sources, labelID: mailbox.id, limit: threadLimit)
        threadsTask = Task { [weak self] in
            do {
                for try await threads in stream {
                    guard let self, !Task.isCancelled, !isStopped, selectedMailbox == mailbox else { return }
                    self.threads = threads
                    listChanged()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.selectedAccounts.forEach { $0.cacheReadFailed() }
            }
        }
    }

    /// Leaves a label that's gone for its account's Inbox.
    private func labelsChanged() {
        guard !isStopped, case .account(let accountID, let id)? = selectedMailbox, id != Self.outboxID,
              id != AttachmentLibraryModel.mailboxID,
              !SystemMailbox.all.contains(where: { $0.id == id }),
              let owner = account(id: accountID), !owner.labels.contains(where: { $0.id == id })
        else { return }
        selectedMailbox = .account(accountID, SystemLabel.inbox)
    }

    /// The accounts whose mail the selected mailbox shows.
    var selectedAccounts: [AccountMailbox] {
        selectedMailbox.map(owners(of:)) ?? []
    }

    private func owners(of box: MailboxID) -> [AccountMailbox] {
        switch box {
        case .account(let accountID, _): account(id: accountID).map { [$0] } ?? []
        case .combined: accounts
        }
    }

    private func snoozedChanged() {
        guard !isStopped, selectedLabelID == Self.snoozedID else { return }
        threads = snoozedThreads()
        listChanged()
    }

    /// The selected accounts' snoozed conversations, the soonest to wake first.
    private func snoozedThreads() -> [ThreadRecord] {
        let sources = Set(selectedAccounts.map(\.account.id))
        return snoozed.filter { sources.contains($0.thread.accountID) }.map(\.thread)
    }

    private func wire(_ account: AccountMailbox) {
        account.onLabelsChange = { [weak self] in self?.labelsChanged() }
        account.onSnoozedChange = { [weak self] in self?.snoozedChanged() }
        account.onEvent = { [weak self] in self?.handle($0) }
    }

    /// Keeps search and a combined mailbox's list in step with the accounts.
    private func accountsChanged() {
        updateSearchSources()
        if case .combined? = selectedMailbox { observeThreads() }
    }

    private func updateSearchSources() {
        search.setSources(searchedAccounts.map { .init(accountID: $0.account.id, engine: $0.engine) })
    }

    /// Keeps the selection inside the list, and tells the engine what the
    /// list shows so expired search holds don't drop it.
    private func listChanged() {
        let threads = listedThreads
        selectedThreadIDs.formIntersection(threads.map(\.key))
        let shown = Dictionary(grouping: threads, by: \.accountID)
        for account in accounts {
            account.engine.setVisibleThreads(Set(shown[account.account.id, default: []].map(\.id)))
        }
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
            notice = Notice(message: "This draft changed elsewhere. Both versions were kept.")
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

    /// The j and k keys: selects the conversation below or above the
    /// selection, stopping at the ends, or the first one when none is selected.
    func selectAdjacentThread(_ offset: Int) {
        let threads = listedThreads
        guard !threads.isEmpty else { return }
        let selected = threads.indices.filter { selectedThreadIDs.contains(threads[$0].key) }
        let index = if offset > 0, let last = selected.last {
            min(last + offset, threads.count - 1)
        } else if offset < 0, let first = selected.first {
            max(first + offset, 0)
        } else {
            0
        }
        selectedThreadIDs = [threads[index].key]
    }

    /// Moves the selection to the thread below the ones leaving the list, or above if none is below.
    func selectThread(after leaving: Set<ThreadKey>) {
        let threads = listedThreads
        guard leaving == selectedThreadIDs,
              let lastIndex = threads.lastIndex(where: { leaving.contains($0.key) })
        else { return }
        let below = threads[(lastIndex + 1)...].first { !leaving.contains($0.key) }
        let above = threads[..<lastIndex].last { !leaving.contains($0.key) }
        selectedThreadIDs = (below ?? above).map { [$0.key] } ?? []
    }

    /// The Gmail thread IDs the engine takes, in a stable order.
    static func threadIDs(_ keys: Set<ThreadKey>) -> [String] {
        keys.sorted().map(\.threadID)
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

/// One account's part of a command, queued by `queueUndoable`.
@MainActor
private struct UndoStep {
    let account: AccountMailbox
    let run: @MainActor () async throws -> ActionReceipt?
}

/// The target of one Edit > Undo entry. The model keeps it alive until the
/// entry is used or removed.
@MainActor
private final class UndoEntry {
    struct Applied {
        let account: AccountMailbox
        let receipt: ActionReceipt
    }

    let id = UUID()
    let name: String
    /// Undoes each change instead of its account's engine. Nil uses the engines.
    let revert: MailboxModel.Revert?
    /// Each account's change, in the order made.
    var applied: [Applied] = []
    /// The first change's receipt, which the notice's Undo carries.
    var handle: ActionReceipt?
    /// Until the queued steps have all run.
    var isQueued = true
    var undoRequested = false
    var isApplying = false

    init(name: String, revert: MailboxModel.Revert? = nil) {
        self.name = name
        self.revert = revert
    }
}

/// A conversation in one account. Gmail thread IDs are only unique within
/// their account, so lists and selections use this.
struct ThreadKey: Hashable, Comparable, Sendable {
    let accountID: String
    let threadID: String

    static func < (lhs: ThreadKey, rhs: ThreadKey) -> Bool {
        (lhs.accountID, lhs.threadID) < (rhs.accountID, rhs.threadID)
    }
}

extension ThreadRecord {
    var key: ThreadKey { ThreadKey(accountID: accountID, threadID: id) }
}

/// A mailbox the sidebar lists: one account's, or the same mailbox across
/// every account. `id` is a Gmail label ID or one of Tern's own mailboxes.
enum MailboxID: Hashable, Sendable {
    case combined(String)
    case account(String, String)

    var id: String {
        switch self {
        case .combined(let id), .account(_, let id): id
        }
    }
}

/// The sidebar's mailboxes in order: Gmail's system labels and Tern's Snoozed.
struct SystemMailbox: Identifiable {
    let id: String
    let title: String
    let systemImage: String

    /// In sidebar order. With several accounts each lists every account's mail.
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

    /// The mailboxes ⌘1 to ⌘5 open.
    static let numbered = Array(all.prefix(5))

    /// Listed after Drafts while it has items.
    static let outbox = SystemMailbox(id: MailboxModel.outboxID, title: "Outbox", systemImage: "tray.and.arrow.up")
}
