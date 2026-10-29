import AppKit
import GmailAPI
import MailStore
import Observation
import SyncEngine

/// The signed-in mailbox: what the sidebar, thread list and commands read,
/// and the actions they send to the sync engine.
@MainActor
@Observable
final class MailboxModel {
    enum SyncStatus: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    /// A short message at the bottom of the window, with Undo when it can be reverted.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let undo: PendingAction?
        var isError = false
    }

    static let pageSize = 200

    let account: AccountRecord
    private let cache: MailCache
    private let engine: SyncEngine

    var selectedLabelID: String? = SystemLabel.inbox {
        didSet {
            guard selectedLabelID != oldValue else { return }
            selectedThreadIDs = []
            threadLimit = Self.pageSize
            observeThreads()
        }
    }
    var selectedThreadIDs: Set<String> = []
    var notice: Notice?

    private(set) var labels: [LabelRecord] = []
    private(set) var threads: [ThreadRecord] = []
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var hasSyncedOnce = false

    /// The window's undo manager, so Edit > Undo reverts mail actions.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var threadLimit = pageSize
    @ObservationIgnored private var undoneActionIDs = Set<Int64>()
    /// Edit > Undo entries by action ID, so undoing from the notice can remove one.
    @ObservationIgnored private var undoEntries: [Int64: UndoEntry] = [:]
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var threadsTask: Task<Void, Never>?

    init(account: AccountRecord, cache: MailCache, gmail: any GmailService) {
        self.account = account
        self.cache = cache
        self.engine = SyncEngine(accountID: account.id, gmail: gmail, cache: cache)
    }

    func start() async {
        hasSyncedOnce = (try? await cache.syncState(accountID: account.id)) != nil
        guard !isStopped else { return }
        let labelStream = cache.labels(accountID: account.id)
        let events = engine.events
        tasks.append(Task { [weak self] in
            do {
                for try await labels in labelStream { self?.labels = labels }
            } catch {
                self?.syncStatus = .failed("Tern couldn't read its mail cache.")
            }
        })
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        observeThreads()
        await engine.start()
    }

    /// Returns once the engine has stopped writing to the cache.
    func stop() async {
        isStopped = true
        tasks.forEach { $0.cancel() }
        tasks = []
        threadsTask?.cancel()
        for entry in undoEntries.values {
            undoManager?.removeAllActions(withTarget: entry)
        }
        undoEntries = [:]
        await engine.stop()
    }

    func syncNow() {
        let engine = engine
        Task { await engine.syncReportingErrors() }
    }

    // MARK: Reading

    var selectedThreads: [ThreadRecord] {
        threads.filter { selectedThreadIDs.contains($0.id) }
    }

    var userLabels: [LabelRecord] {
        labels.filter { !$0.isSystem }
    }

    func label(id: String) -> LabelRecord? {
        labels.first { $0.id == id }
    }

    var selectedLabelTitle: String {
        guard let id = selectedLabelID else { return "Tern" }
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
            notice = Notice(message: "Tern couldn't load this conversation. Check your connection.", undo: nil, isError: true)
        }
    }

    func loadMoreThreads() {
        guard threads.count >= threadLimit else { return }
        threadLimit += Self.pageSize
        observeThreads()
    }

    // MARK: Actions

    func perform(_ action: MailAction, on threadIDs: Set<String>? = nil) {
        let ids = Array(threadIDs ?? selectedThreadIDs)
        guard !ids.isEmpty else { return }
        if action == .archive || action == .trash {
            selectThread(after: Set(ids))
        }
        let engine = engine
        Task {
            do {
                guard let row = try await engine.perform(action, threadIDs: ids), !isStopped else { return }
                registerUndo(row, name: Self.undoName(action))
                if let message = Self.confirmation(action, count: ids.count) {
                    notice = Notice(message: message, undo: row)
                }
            } catch {
                guard !isStopped else { return }
                notice = Notice(message: "Tern couldn't save that change.", undo: nil, isError: true)
            }
        }
    }

    /// Reverts an action, from the notice, a menu or Edit > Undo.
    func undo(_ row: PendingAction) {
        if let id = row.id {
            guard undoneActionIDs.insert(id).inserted else { return }
            // Undone from somewhere else: drop its Edit > Undo entry so the menu stays in step.
            if let entry = undoEntries.removeValue(forKey: id), let undoManager, !undoManager.isUndoing {
                undoManager.removeAllActions(withTarget: entry)
            }
        }
        if notice?.undo == row { notice = nil }
        let engine = engine
        Task {
            do {
                try await engine.undo(row)
            } catch {
                notice = Notice(message: "Tern couldn't undo that change.", undo: nil, isError: true)
            }
        }
    }

    /// True when every thread in `ids` is read, so commands offer Mark as Unread.
    func allRead(_ ids: Set<String>) -> Bool {
        !threads.contains { ids.contains($0.id) && $0.isUnread }
    }

    func allStarred(_ ids: Set<String>) -> Bool {
        let matching = threads.filter { ids.contains($0.id) }
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

    /// Archiving from Trash or Spam would leave the thread there, so it is offered elsewhere only.
    var canArchive: Bool {
        !selectedThreadIDs.isEmpty && selectedLabelID != SystemLabel.trash && selectedLabelID != SystemLabel.spam
    }

    var canTrash: Bool {
        !selectedThreadIDs.isEmpty && selectedLabelID != SystemLabel.trash
    }

    // MARK: Private

    private func observeThreads() {
        threadsTask?.cancel()
        guard let labelID = selectedLabelID else {
            threads = []
            return
        }
        let stream = cache.threads(accountID: account.id, labelID: labelID, limit: threadLimit)
        threadsTask = Task { [weak self] in
            do {
                for try await threads in stream { self?.threads = threads }
            } catch {
                self?.syncStatus = .failed("Tern couldn't read its mail cache.")
            }
        }
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .syncStarted:
            syncStatus = .syncing
        case .syncFinished(let date):
            syncStatus = .idle
            lastSyncedAt = date
            hasSyncedOnce = true
        case .syncFailed(let message):
            syncStatus = .failed(message)
        case .actionFailed(let message):
            notice = Notice(message: message, undo: nil, isError: true)
        }
    }

    /// Moves the selection to the thread below the ones leaving the list, or above if none is below.
    private func selectThread(after leaving: Set<String>) {
        guard leaving == selectedThreadIDs,
              let lastIndex = threads.lastIndex(where: { leaving.contains($0.id) })
        else { return }
        let below = threads[(lastIndex + 1)...].first { !leaving.contains($0.id) }
        let above = threads[..<lastIndex].last { !leaving.contains($0.id) }
        selectedThreadIDs = (below ?? above).map { [$0.id] } ?? []
    }

    private func registerUndo(_ row: PendingAction, name: String) {
        guard let undoManager, let id = row.id else { return }
        let entry = UndoEntry()
        undoEntries[id] = entry
        undoManager.registerUndo(withTarget: entry) { [weak self] _ in
            // The window's undo manager only runs its handlers on the main thread.
            MainActor.assumeIsolated { self?.undo(row) }
        }
        undoManager.setActionName(name)
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
private final class UndoEntry {}

/// Gmail's system labels in sidebar order.
struct SystemMailbox: Identifiable {
    let id: String
    let title: String
    let systemImage: String

    static let all = [
        SystemMailbox(id: SystemLabel.inbox, title: "Inbox", systemImage: "tray"),
        SystemMailbox(id: SystemLabel.starred, title: "Starred", systemImage: "star"),
        SystemMailbox(id: SystemLabel.sent, title: "Sent", systemImage: "paperplane"),
        SystemMailbox(id: SystemLabel.draft, title: "Drafts", systemImage: "doc"),
        SystemMailbox(id: SystemLabel.allMail, title: "All Mail", systemImage: "archivebox"),
        SystemMailbox(id: SystemLabel.spam, title: "Spam", systemImage: "xmark.bin"),
        SystemMailbox(id: SystemLabel.trash, title: "Trash", systemImage: "trash"),
    ]
}
