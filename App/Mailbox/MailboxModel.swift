import Foundation
import MailStore
import MessageContent
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
        let undo: ActionReceipt?
        var isError = false
    }

    static let pageSize = 200
    static let undoLimit = 100

    let account: AccountRecord
    private let cache: MailCache
    private let engine: SyncEngine

    var selectedLabelID: String? = SystemLabel.inbox {
        didSet {
            guard selectedLabelID != oldValue else { return }
            selectedThreadIDs = []
            threads = []
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

    /// The retained targets are bounded along with UndoManager's history.
    var retainedUndoCount: Int { undoEntries.count }
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var threadsTask: Task<Void, Never>?

    /// `outgoingDirectory` holds copies of the files attached to drafts.
    init(account: AccountRecord, cache: MailCache, gmail: any GmailService, outgoingDirectory: URL) {
        self.account = account
        self.cache = cache
        self.engine = SyncEngine(
            accountID: account.id,
            sender: EmailAddress(name: account.displayName, address: account.email),
            outgoingDirectory: outgoingDirectory,
            gmail: gmail,
            cache: cache
        )
    }

    func start() async {
        hasSyncedOnce = (try? await cache.syncState(accountID: account.id)) != nil
        guard !isStopped else { return }
        let labelStream = cache.labels(accountID: account.id)
        let events = engine.events
        tasks.append(Task { [weak self] in
            do {
                for try await labels in labelStream {
                    guard let self, !Task.isCancelled, !isStopped else { return }
                    self.labels = labels
                    if let id = selectedLabelID,
                       !SystemMailbox.all.contains(where: { $0.id == id }),
                       !labels.contains(where: { $0.id == id }) {
                        selectedLabelID = SystemLabel.inbox
                    }
                }
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
        actionTask?.cancel()
        for entry in undoEntries.values {
            undoManager?.removeAllActions(withTarget: entry)
        }
        undoEntries = [:]
        undoOrder = []
        await engine.stop()
    }

    func syncNow() {
        let engine = engine
        Task { await engine.syncReportingErrors() }
    }

    // MARK: Reading

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

    @discardableResult
    func perform(_ action: MailAction, on threadIDs: Set<String>? = nil) -> Task<Void, Never>? {
        let ids = Array(threadIDs ?? selectedThreadIDs)
        guard !ids.isEmpty, !isStopped else { return nil }
        if (action == .archive && selectedLabelID == SystemLabel.inbox)
            || (action == .trash && selectedLabelID != SystemLabel.trash) {
            selectThread(after: Set(ids))
        }
        // Register inside the initiating event. The target can remember an undo
        // requested before its durable queue rows have been returned.
        let entry = UndoEntry(name: Self.undoName(action))
        registerUndo(entry)
        let previous = actionTask
        let engine = engine
        let task = Task {
            await previous?.value
            guard !isStopped, !Task.isCancelled else { return }
            do {
                guard let row = try await engine.perform(action, threadIDs: ids), !isStopped else { return }
                entry.receipt = row
                if entry.undoRequested {
                    await requestUndo(entry)?.value
                } else if let message = Self.confirmation(action, count: ids.count) {
                    notice = Notice(message: message, undo: row)
                }
            } catch {
                removeUndo(entry)
                guard !isStopped else { return }
                notice = Notice(message: "Tern couldn't save that change.", undo: nil, isError: true)
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
        return Task {
            do {
                try await engine.undo(row)
                removeUndo(entry)
                if notice?.undo?.id == row.id { notice = nil }
            } catch {
                guard !isStopped else { return }
                entry.isApplying = false
                entry.undoRequested = false
                registerUndo(entry)
                notice = Notice(message: "Tern couldn't undo that change. Try again.", undo: row, isError: true)
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
                for try await threads in stream {
                    guard let self, !Task.isCancelled, !isStopped, selectedLabelID == labelID else { return }
                    self.threads = threads
                    selectedThreadIDs.formIntersection(threads.map(\.id))
                }
            } catch {
                guard !Task.isCancelled else { return }
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
        case .actionFailed(let message), .draftFailed(_, let message):
            notice = Notice(message: message, undo: nil, isError: true)
        case .draftCopied:
            notice = Notice(message: "Another app changed this draft, so Tern kept both versions.", undo: nil, isError: false)
        case .draftSent:
            break
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
    var receipt: ActionReceipt?
    var undoRequested = false
    var isApplying = false

    init(name: String) { self.name = name }
}

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
