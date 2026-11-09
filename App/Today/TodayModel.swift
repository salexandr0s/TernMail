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
    var searchText = ""
    var searchFocusRequest = 0
    var filter: TodayFilter = .briefing
    private(set) var activeVisitID: UUID?
    private(set) var historyReady = false
    private(set) var historyError: String?
    private(set) var isLoadingHistory = false
    private var historyRevision = 0
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

    init(followUps: FollowUpsModel, context: @escaping @MainActor () -> TodayVisitContext,
         canPresent: @escaping @MainActor () -> Bool = { true },
         now: @escaping @MainActor () -> Date = { .now }, calendar: @escaping @MainActor () -> Calendar = { .current },
         readHistory: @escaping ReadHistory, saveHistory: @escaping SaveHistory) {
        self.followUps = followUps; contextProvider = context; self.canPresent = canPresent
        self.now = now; self.calendar = calendar; self.readHistory = readHistory; self.saveHistory = saveHistory
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
        // Reading historyRevision also makes successful baseline loads observable.
        _ = historyRevision
        let context = visitContext
        return TodayProjection.make(entries: followUps.entries, accountIDs: context.accountIDs,
            baseline: activeContext == context && historyReady ? baseline : nil,
            replyChecks: followUps.replyCheckStates, filter: filter, searchText: searchText, now: date, calendar: calendar())
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
            guard isCurrent(id, context: context) else { return }
            guard value.scope == context.scope, value.accountIDs == context.accountIDs else { throw TodayVisitStoreError.unavailableScope }
            baseline = value; historyReady = true; historyError = nil; historyRevision += 1
        } catch is CancellationError {} catch {
            if isCurrent(id, context: context) { historyError = "Recent-change tracking is unavailable. Refresh to try again." }
        }
    }

    /// Called by native rows that actually appeared, or by a rendered empty state.
    /// The first successful account visit is the one documented census exception.
    func acknowledgePresented(_ rows: [TodayRow], visitID: UUID) async {
        guard let context = activeContext, isCurrent(visitID, context: context), historyReady,
              followUps.hasLoadedEntries, let previous = baseline else { return }
        let currentProjection = projection(now: now())
        let displayed = Dictionary(uniqueKeysWithValues: currentProjection.rows.map { ($0.id, $0.snapshot) })
        let canonical = Dictionary(uniqueKeysWithValues: followUps.entries.map { ($0.id, $0) })
        let valid = rows.compactMap { row -> CommitmentEntry? in
            guard displayed[row.id] == row.snapshot, let entry = canonical[row.id],
                  TodayCommitmentSnapshot(entry: entry) == row.snapshot else { return nil }
            // Preserve the revision of the actually presented row. Replacing
            // it with the latest record could let an older callback overwrite
            // a newer acknowledgement after a semantic edit-and-revert.
            return row.entry
        }
        guard rows.isEmpty ? currentProjection.rowCount == 0 : !valid.isEmpty else { return }
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

    private func isCurrent(_ id: UUID, context: TodayVisitContext) -> Bool {
        !Task.isCancelled && canPresent() && activeVisitID == id && activeContext == context && visitContext == context
    }
}
