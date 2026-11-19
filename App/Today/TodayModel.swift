import AppKit
import Foundation
import MailStore
import Observation

struct TodayVisitContext: Hashable {
    let scope: TodayScope
    let accountIDs: Set<String>
}

@MainActor @Observable
final class TodayModel {
    typealias ReadHistory = @MainActor (TodayVisitContext) async throws -> TodayVisitBaseline
    typealias SaveHistory = @MainActor (TodayVisitContext, [CommitmentEntry], [CommitmentEntry], Date) async throws -> TodayVisitAcknowledgement

    let followUps: FollowUpsModel
    var searchText = "" { didSet { if searchText != oldValue { refreshPresentation() } } }
    var searchFocusRequest = 0
    var filter: TodayFilter = .briefing { didSet { if filter != oldValue { refreshPresentation() } } }
    /// The follow-up list the page draws. It is rebuilt when its inputs change and
    /// replaced only when the result differs, so drawing the page never projects the entries again.
    private(set) var presentation = TodayPresentation(projection: TodayProjection(sections: []), filter: .briefing, now: .now)
    private(set) var activeVisitID: UUID?
    private(set) var historyReady = false
    private(set) var historyError: String?
    private(set) var isLoadingHistory = false
    /// Counts changes to the visit and its baseline. Each one can change what the rows say.
    private var historyRevision = 0 { didSet { refreshPresentation() } }
    @ObservationIgnored private let contextProvider: @MainActor () -> TodayVisitContext
    @ObservationIgnored private let canPresent: @MainActor () -> Bool
    @ObservationIgnored private let readHistory: ReadHistory
    @ObservationIgnored private let saveHistory: SaveHistory
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: @MainActor () -> Calendar
    @ObservationIgnored private var activeContext: TodayVisitContext?
    @ObservationIgnored private var baseline: TodayVisitBaseline?
    @ObservationIgnored private var acknowledged: [String: TodayCommitmentSnapshot] = [:]
    @ObservationIgnored private var loadTask: Task<TodayVisitBaseline, Error>?
    @ObservationIgnored private var saveTasks: [UUID: Task<TodayVisitAcknowledgement, Error>] = [:]
    @ObservationIgnored private var visiblePresentation: (rows: [TodayRow], visitID: UUID)?
    @ObservationIgnored private var visibleTask: Task<Void, Never>?
    /// The follow-ups revision `presentation` was last built from.
    @ObservationIgnored private var preparedEntriesRevision = -1

    init(followUps: FollowUpsModel, context: @escaping @MainActor () -> TodayVisitContext,
         canPresent: @escaping @MainActor () -> Bool = { true },
         now: @escaping @MainActor () -> Date = { .now }, calendar: @escaping @MainActor () -> Calendar = { .current },
         readHistory: @escaping ReadHistory, saveHistory: @escaping SaveHistory) {
        self.followUps = followUps; contextProvider = context; self.canPresent = canPresent
        self.now = now; self.calendar = calendar; self.readHistory = readHistory; self.saveHistory = saveHistory
        refreshPresentation()
        followPresentationInputs()
    }

    convenience init(app: AppModel?) {
        self.init(followUps: app?.followUps ?? FollowUpsModel(app: nil), context: { [weak app] in
            TodayVisitContext(scope: app?.accountPreferences?.activeProfileID.map(TodayScope.profile) ?? .all,
                accountIDs: app?.accountPreferences?.visibleAccountIDs ?? Set(app?.mailbox?.presentedAccounts.map(\.account.id) ?? []))
        }, canPresent: { [weak app] in
            guard let app else { return false }
            return NSApp.isActive && app.destination == .today && app.mailbox != nil
        }, readHistory: { [weak app] context in
            guard let store = app?.mailbox?.accountStore else { throw FollowUpModelError.unavailable }
            return try await store.todayVisitBaseline(scope: context.scope, accountIDs: context.accountIDs)
        }, saveHistory: { [weak app] context, presented, initial, date in
            guard let store = app?.mailbox?.accountStore else { throw FollowUpModelError.unavailable }
            return try await store.acknowledgeTodayVisit(scope: context.scope, accountIDs: context.accountIDs,
                presentedEntries: presented, initialEntries: initial, now: date)
        })
    }

    var visitContext: TodayVisitContext { contextProvider() }
    var isLoading: Bool { followUps.isLoading || isLoadingHistory }
    var hasLoadedEntries: Bool { followUps.hasLoadedEntries }
    var presentationRevision: Int { followUps.presentationRevision + historyRevision }

    func projection(now date: Date) -> TodayProjection {
        let context = visitContext
        return TodayProjection.make(entries: followUps.entries, accountIDs: context.accountIDs,
            baseline: activeContext == context && historyReady ? baseline : nil,
            replyChecks: followUps.replyCheckStates, filter: filter, searchText: searchText, now: date, calendar: calendar())
    }

    /// Rebuilds the list from the current follow-ups, visit history, filter and search.
    /// The filter, the search and the visit history call it when they change. The page
    /// calls it when it comes on screen and each minute while it stays there, because
    /// due and snoozed rows also move with the clock.
    func refreshPresentation() {
        preparedEntriesRevision = followUps.presentationRevision
        let date = now()
        let value = TodayPresentation(projection: projection(now: date), filter: filter, now: date)
        if value != presentation { presentation = value }
    }

    /// Follow-ups, reply checks and the visible accounts belong to other models.
    /// This rebuilds the list after one of them changes and keeps one observation open.
    /// The rebuild runs on the main actor from the values of that moment, so an
    /// older result can never replace a newer one.
    private func followPresentationInputs() {
        withObservationTracking {
            _ = followUps.entries
            _ = followUps.replyCheckStates
            _ = visitContext
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPresentation()
                self.followPresentationInputs()
            }
        }
    }

    func beginVisit() async {
        guard canPresent(), !Task.isCancelled else { return }
        let context = visitContext
        if activeVisitID != nil, activeContext == context, historyReady || isLoadingHistory { return }
        endVisit()
        let id = UUID()
        activeVisitID = id; activeContext = context
        if !followUps.hasLoadedEntries { await followUps.refresh(checkReminders: false) }
        guard isCurrent(id, context: context), followUps.hasLoadedEntries else { return }
        await loadBaseline(id: id, context: context)
    }

    func endVisit() {
        activeVisitID = nil; activeContext = nil; baseline = nil; acknowledged = [:]
        loadTask?.cancel(); loadTask = nil
        for task in saveTasks.values { task.cancel() }
        visiblePresentation = nil; visibleTask?.cancel(); visibleTask = nil
        saveTasks = [:]; historyReady = false; isLoadingHistory = false; historyError = nil
        historyRevision += 1
    }

    func refresh() async {
        await followUps.refresh(checkReminders: false)
        guard canPresent(), !Task.isCancelled else { return }
        if activeContext != visitContext || activeVisitID == nil { await beginVisit(); return }
        if let id = activeVisitID, let context = activeContext, !historyReady, !isLoadingHistory {
            await loadBaseline(id: id, context: context)
        }
        historyRevision += 1
    }

    private func loadBaseline(id: UUID, context: TodayVisitContext) async {
        guard isCurrent(id, context: context), followUps.hasLoadedEntries else { return }
        isLoadingHistory = true
        defer { if activeVisitID == id { isLoadingHistory = false; loadTask = nil } }
        let task = Task { try Task.checkCancellation(); return try await readHistory(context) }
        loadTask = task
        do {
            let value = try await task.value
            // The task that began the read may be cancelled by now, for example
            // when the page's view task restarts. A later beginVisit() returns
            // early while a read runs, so the result counts as long as the visit
            // is open. endVisit() closes the visit and cancels its read.
            guard isVisitOpen(id, context: context) else { return }
            guard value.scope == context.scope, value.accountIDs == context.accountIDs else { throw TodayVisitStoreError.unavailableScope }
            baseline = value; historyReady = true; historyError = nil; historyRevision += 1
        } catch is CancellationError {} catch {
            if isVisitOpen(id, context: context) { historyError = "Recent-change tracking is unavailable. Refresh to try again." }
        }
    }

    /// Queues the rows that are on screen now, or none for a rendered empty state.
    /// Saves run one at a time and a newer list replaces a waiting one, so a
    /// scroll or a change never starts one save per row.
    func acknowledgeVisible(_ rows: [TodayRow], visitID: UUID) {
        visiblePresentation = (rows, visitID)
        guard visibleTask == nil else { return }
        visibleTask = Task { [weak self] in
            while !Task.isCancelled, let self, let next = self.visiblePresentation {
                self.visiblePresentation = nil
                await self.acknowledgePresented(next.rows, visitID: next.visitID)
            }
            // endVisit() has already let go of a cancelled task.
            if !Task.isCancelled { self?.visibleTask = nil }
        }
    }

    /// Saves rows that actually appeared, or a rendered empty state.
    /// The first successful account visit is the one documented census exception.
    func acknowledgePresented(_ rows: [TodayRow], visitID: UUID) async {
        guard let context = activeContext, isCurrent(visitID, context: context), historyReady,
              followUps.hasLoadedEntries, let previous = baseline else { return }
        // Changed entries reach the prepared list one step later. Catch up before trusting it.
        if preparedEntriesRevision != followUps.presentationRevision { refreshPresentation() }
        let shown = presentation.rows
        let displayed = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0.snapshot) })
        let canonical = Dictionary(uniqueKeysWithValues: followUps.entries.map { ($0.id, $0) })
        let valid = rows.compactMap { row -> CommitmentEntry? in
            guard displayed[row.id] == row.snapshot, let entry = canonical[row.id],
                  TodayCommitmentSnapshot(entry: entry) == row.snapshot else { return nil }
            // Preserve the revision of the actually presented row. Replacing
            // it with the latest record could let an older callback overwrite
            // a newer acknowledgement after a semantic edit-and-revert.
            return row.entry
        }
        guard rows.isEmpty ? shown.isEmpty : !valid.isEmpty else { return }
        let presented = valid.filter { acknowledged[$0.id] != TodayCommitmentSnapshot(entry: $0) }
        let missingAccounts = context.accountIDs.subtracting(previous.initializedAccountIDs)
        guard !presented.isEmpty || !missingAccounts.isEmpty else { return }
        let initial = followUps.entries.filter { context.accountIDs.contains($0.record.accountID) }
        let requestID = UUID(), date = now()
        let task = Task {
            try Task.checkCancellation()
            guard isCurrent(visitID, context: context) else { throw CancellationError() }
            return try await saveHistory(context, presented, initial, date)
        }
        saveTasks[requestID] = task
        defer { saveTasks[requestID] = nil }
        do {
            let result = try await task.value
            guard isCurrent(visitID, context: context), let fixed = baseline else { return }
            for entry in presented where result.acknowledgedIDs.contains(entry.id) {
                acknowledged[entry.id] = TodayCommitmentSnapshot(entry: entry)
            }
            let seeded = result.initializedAccountIDs.subtracting(fixed.initializedAccountIDs)
            if !seeded.isEmpty {
                var snapshots = fixed.snapshots
                for entry in initial where seeded.contains(entry.record.accountID) { snapshots[entry.id] = TodayCommitmentSnapshot(entry: entry) }
                baseline = TodayVisitBaseline(scope: context.scope, accountIDs: context.accountIDs,
                    initializedAccountIDs: fixed.initializedAccountIDs.union(seeded), snapshots: snapshots)
                historyRevision += 1
            }
            historyError = nil
        } catch is CancellationError {} catch {
            if isCurrent(visitID, context: context) { historyError = "Recent-change tracking couldn't be saved. Refresh to try again." }
        }
    }

    /// Whether the calling task may still act for the visit.
    private func isCurrent(_ id: UUID, context: TodayVisitContext) -> Bool {
        !Task.isCancelled && isVisitOpen(id, context: context)
    }

    /// Whether the visit is still open, whichever task asks.
    private func isVisitOpen(_ id: UUID, context: TodayVisitContext) -> Bool {
        canPresent() && activeVisitID == id && activeContext == context && visitContext == context
    }
}
