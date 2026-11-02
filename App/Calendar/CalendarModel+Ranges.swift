import Dispatch
import Diagnostics
import Foundation
import GmailAPI
import MailStore
import SyncEngine

struct CalendarRangeIdentity: Hashable, Sendable {
    let interval: DateInterval
    let timeZone: String
    let firstWeekday: Int
    let mode: String
    let lifecycle: Int
    let owners: [String]

    static func displayInterval(containing date: Date, mode: CalendarDisplayMode, calendar: Calendar) -> DateInterval {
        if mode == .month {
            let days = CalendarLayout.monthDays(containing: date, calendar: calendar)
            if let first = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) {
                return DateInterval(start: first, end: end)
            }
        }
        return calendar.dateInterval(of: mode.component, for: date) ?? DateInterval(start: date, duration: 86400)
    }
}

/// Owns the dispatch source independently of actor isolation so teardown can
/// cancel it immediately. The callback only schedules work on the main actor.
final class CalendarRangeMemoryPressure {
    private let source: any DispatchSourceMemoryPressure

    init(onPressure: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler(handler: onPressure)
        source.resume()
    }

    deinit { source.cancel() }
}

struct CalendarRangeSnapshot: Sendable {
    let presentation: CalendarPresentationSnapshot
    let checkedAt: Date?
    let stale: Bool
    let byteCost: Int
}

private struct CalendarOwnerRange: Sendable {
    let owner: CalendarDisplayCalendar
    let result: CalendarOccurrenceResult?
    var accessDenied = false
}

extension CalendarModel {
    var rangeIdentity: CalendarRangeIdentity {
        CalendarRangeIdentity(interval: displayInterval, timeZone: calendar.timeZone.identifier,
            firstWeekday: calendar.firstWeekday, mode: mode.rawValue, lifecycle: lifecycleRevision,
            owners: calendars.filter(\.isVisible).map(\.id).sorted())
    }

    /// Navigation reuses a prepared range and only refreshes it when missing or
    /// older than a minute. Explicit Refresh and edits use reloadOccurrences.
    func activateRange() async {
        let key = rangeIdentity
        if adjacentRangeTask?.key != key { cancelAdjacentRangePreparation() }
        if let saved = rangeSnapshots[key] {
            publish(saved)
            touchRange(key)
            scheduleAdjacentRangePreparation()
            if let checked = saved.checkedAt, Date.now.timeIntervalSince(checked) < 60 { return }
        }
        if let activeRangeTask, activeRangeTask.key == key, !activeRangeTask.task.isCancelled {
            await activeRangeTask.task.value
            return
        }
        activeRangeTask?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await reloadOccurrences()
        }
        activeRangeTask = (key, id, task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if activeRangeTask?.id == id { activeRangeTask = nil }
    }

    func invalidateRangeSnapshots() {
        cancelAdjacentRangePreparation()
        rangeSnapshots.removeAll()
        rangeSnapshotOrder.removeAll()
        completedSearch = nil
        searchCompletedAt = nil
    }

    func cancelAdjacentRangePreparation() {
        adjacentRangeTask?.task.cancel()
        adjacentRangeTask = nil
    }

    /// Synthetic fixtures and externally restored event arrays use the same
    /// preparation path as a fetched range, without accessing any service.
    func preparePresentationForCurrentEvents() async {
        let current = events
        let key = rangeIdentity
        let displayCalendar = calendar
        let interval = displayInterval
        let buildsTimeAxis = mode == .day || mode == .week
        let preparationSpan = TernSignposts.begin(.calendarPreparation)
        let prepared = await Task.detached(priority: .userInitiated) {
            CalendarPresentationSnapshot(events: current, interval: interval, calendar: displayCalendar,
                buildsTimeAxis: buildsTimeAxis)
        }.value
        guard key == rangeIdentity, events == current, !Task.isCancelled else {
            TernSignposts.cancel(preparationSpan); return
        }
        TernSignposts.end(preparationSpan)
        presentation = prepared
        presentationRevision += 1
    }

    func reloadOccurrences(refresh: Bool = true, refreshIfIncomplete: Bool = false) async {
        cancelAdjacentRangePreparation()
        rangeRevision += 1
        let revision = rangeRevision
        let lifecycle = lifecycleRevision
        let key = rangeIdentity
        let interval = displayInterval
        let displayCalendar = calendar
        let owners = calendars.filter(\.isVisible)
        let sources = owners.map { ($0, engines[$0.accountID]) }
        let buildsTimeAxis = mode == .day || mode == .week
        // Local pending changes belong in the first snapshot. Email source-link
        // reconciliation can wait until after the primary range is visible.
        await reloadOperations(reconcileEmailLinks: false)
        guard revision == rangeRevision, lifecycle == lifecycleRevision, !Task.isCancelled else { return }
        let pending = operations
        let allCalendars = calendars
        var needsRefresh = refresh
        for shouldRefresh in [false, true] {
            if shouldRefresh && !needsRefresh { break }
            let loaded = await Self.readRange(sources, interval: interval, refresh: shouldRefresh)
            guard revision == rangeRevision, lifecycle == lifecycleRevision, !Task.isCancelled else { return }
            let denied = loaded.filter(\.accessDenied)
            if !denied.isEmpty {
                for item in denied {
                    handleCalendarAccessFailure(CalendarEngineError.permissionDenied,
                        accountID: item.owner.accountID, calendarID: item.owner.calendarID)
                }
                await reloadOccurrences(refresh: false)
                return
            }
            if refreshIfIncomplete, loaded.contains(where: { $0.result?.isComplete != true }) { needsRefresh = true }
            let preparationSpan = TernSignposts.begin(.calendarPreparation)
            let preparation = Task.detached(priority: .userInitiated) { () throws -> CalendarRangeSnapshot in
                try Self.prepareRangeSnapshot(loaded, operations: pending, calendars: allCalendars,
                    interval: interval, calendar: displayCalendar, buildsTimeAxis: buildsTimeAxis)
            }
            let snapshot = await withTaskCancellationHandler {
                try? await preparation.value
            } onCancel: { preparation.cancel() }
            guard let snapshot, revision == rangeRevision, lifecycle == lifecycleRevision,
                  key == rangeIdentity, allCalendars == calendars, !Task.isCancelled else {
                TernSignposts.cancel(preparationSpan); return
            }
            if pending != operations {
                TernSignposts.cancel(preparationSpan)
                await reloadOccurrences(refresh: false); return
            }
            TernSignposts.end(preparationSpan)
            publish(snapshot)
            remember(snapshot, for: key)
            scheduleAdjacentRangePreparation()
        }
        guard revision == rangeRevision, lifecycle == lifecycleRevision, !Task.isCancelled else { return }
        Task { [weak self] in
            guard let self, lifecycle == lifecycleRevision else { return }
            await reconcileEmailSourceLinks()
        }
    }

    /// Only complete local ranges are speculative inputs. A missing range stays
    /// a foreground request, and preparation never changes the visible snapshot.
    private func scheduleAdjacentRangePreparation() {
        guard isVisible, !calendars.isEmpty else { return }
        let key = rangeIdentity
        let revision = rangeRevision
        if let adjacentRangeTask, adjacentRangeTask.key == key, adjacentRangeTask.revision == revision,
           !adjacentRangeTask.task.isCancelled { return }
        cancelAdjacentRangePreparation()
        let displayCalendar = calendar
        let displayMode = mode
        let allCalendars = calendars
        let sources = calendars.filter(\.isVisible).map { ($0, engines[$0.accountID]) }
        guard !sources.isEmpty else { return }
        let pending = operations
        let buildsTimeAxis = mode == .day || mode == .week
        let neighbors = [-1, 1].compactMap { offset -> CalendarRangeIdentity? in
            guard let adjacentDate = displayCalendar.date(byAdding: displayMode.component, value: offset, to: date) else { return nil }
            let interval = CalendarRangeIdentity.displayInterval(containing: adjacentDate, mode: displayMode, calendar: displayCalendar)
            return CalendarRangeIdentity(interval: interval, timeZone: key.timeZone, firstWeekday: key.firstWeekday,
                mode: key.mode, lifecycle: key.lifecycle, owners: key.owners)
        }
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && isVisible && key == rangeIdentity && revision == rangeRevision
                    && pending == operations && allCalendars == calendars
            }
            for neighbor in neighbors {
                guard isCurrent() else { return }
                if rangeSnapshots[neighbor] != nil { continue }
                let loaded = await Self.readRange(sources, interval: neighbor.interval, refresh: false)
                guard isCurrent() else { return }
                guard loaded.count == sources.count,
                      loaded.allSatisfy({ !$0.accessDenied && $0.result?.isComplete == true }) else { continue }
                let span = TernSignposts.begin(.calendarPreparation)
                let preparation = Task.detached(priority: .utility) {
                    try Self.prepareRangeSnapshot(loaded, operations: pending, calendars: allCalendars,
                        interval: neighbor.interval, calendar: displayCalendar, buildsTimeAxis: buildsTimeAxis)
                }
                let snapshot = await withTaskCancellationHandler { try? await preparation.value }
                    onCancel: { preparation.cancel() }
                guard let snapshot, isCurrent() else { TernSignposts.cancel(span); return }
                TernSignposts.end(span)
                remember(snapshot, for: neighbor)
            }
        }
        adjacentRangeTask = (key, revision, task)
    }

    private nonisolated static func prepareRangeSnapshot(_ loaded: [CalendarOwnerRange], operations: [CalendarOperation],
        calendars: [CalendarDisplayCalendar], interval: DateInterval, calendar: Calendar,
        buildsTimeAxis: Bool) throws -> CalendarRangeSnapshot {
        var found: [CalendarDisplayEvent] = []
        for item in loaded {
            for event in item.result?.events ?? [] where !event.isCancelled {
                try Task.checkCancellation()
                found.append(CalendarDisplayEvent(event: event, accountID: item.owner.accountID,
                    calendarID: item.owner.calendarID, colorHex: item.owner.colorHex,
                    canEdit: CalendarEventPermissions.canEdit(event, in: item.owner),
                    fallbackTimeZoneID: calendar.timeZone.identifier))
            }
        }
        let projected = CalendarPendingEvents.project(found, operations: operations, calendars: calendars,
            interval: interval, calendar: calendar)
        try Task.checkCancellation()
        let presentation = CalendarPresentationSnapshot(events: projected, interval: interval,
            calendar: calendar, buildsTimeAxis: buildsTimeAxis)
        let encodedBytes = (try? JSONEncoder().encode(projected.map(\.event)).count) ?? 0
        let references = presentation.days.reduce(0) { $0 + (presentation.day($1)?.events.count ?? 0) }
        let cost = encodedBytes * 2 + projected.count * 512 + references * 512 + presentation.days.count * 256
        let stale = loaded.contains { $0.result?.isStale != false || $0.result?.isComplete != true }
        let checkedAt = stale ? nil : loaded.compactMap { $0.result?.fetchedAt }.min() ?? Date.now
        return CalendarRangeSnapshot(presentation: presentation, checkedAt: checkedAt, stale: stale, byteCost: cost)
    }

    private nonisolated static func readRange(_ sources: [(CalendarDisplayCalendar, CalendarSyncEngine?)],
                                             interval: DateInterval, refresh: Bool) async -> [CalendarOwnerRange] {
        await withTaskGroup(of: CalendarOwnerRange.self) { group in
            var next = 0
            func enqueue(_ source: (CalendarDisplayCalendar, CalendarSyncEngine?)) {
                group.addTask {
                    guard let engine = source.1, !Task.isCancelled else {
                        return CalendarOwnerRange(owner: source.0, result: nil)
                    }
                    do {
                        let result = try await engine.occurrences(calendarID: source.0.calendarID,
                            start: interval.start, end: interval.end, refresh: refresh)
                        return CalendarOwnerRange(owner: source.0, result: result)
                    } catch {
                        let denied: Bool
                        if let google = error as? GmailError {
                            if case .http(status: 403, reason: _) = google { denied = true }
                            else { denied = google == .unauthorized }
                        } else { denied = error as? CalendarEngineError == .permissionDenied }
                        return CalendarOwnerRange(owner: source.0, result: nil, accessDenied: denied)
                    }
                }
            }
            while next < min(4, sources.count) { enqueue(sources[next]); next += 1 }
            var result: [CalendarOwnerRange] = []
            while let loaded = await group.next() {
                result.append(loaded)
                if next < sources.count, !Task.isCancelled { enqueue(sources[next]); next += 1 }
            }
            return result
        }
    }

    private func publish(_ snapshot: CalendarRangeSnapshot) {
        guard presentation?.id != snapshot.presentation.id else { return }
        let changed = presentation?.interval != snapshot.presentation.interval
            || presentation?.calendar != snapshot.presentation.calendar || events != snapshot.presentation.events
        if changed {
            events = snapshot.presentation.events
            presentation = snapshot.presentation
            presentationRevision += 1
        } else if presentation == nil { presentation = snapshot.presentation; presentationRevision += 1 }
        statusText = calendars.isEmpty ? (connectionStates.values.contains(where: \.isEnabled)
            ? "No calendars are available. Refresh or check the account connection." : "Google Calendar isn't connected.")
            : operations.contains(where: { $0.status == .failed || $0.status == .conflicted })
                ? "Some calendar changes need review in Calendar activity."
                : operations.contains(where: { $0.status == .queued || $0.status == .running })
                    ? "Calendar changes are waiting to sync."
                    : snapshot.stale ? "Showing cached events. Some calendars could not be checked." : "Calendars are up to date."
    }

    private func remember(_ snapshot: CalendarRangeSnapshot, for key: CalendarRangeIdentity) {
        let budget = 12 * 1_024 * 1_024
        guard snapshot.byteCost <= budget else {
            rangeSnapshots.removeValue(forKey: key)
            rangeSnapshotOrder.removeAll { $0 == key }
            return
        }
        let prepared = key == rangeIdentity ? presentation ?? snapshot.presentation : snapshot.presentation
        rangeSnapshots[key] = CalendarRangeSnapshot(presentation: prepared,
            checkedAt: snapshot.checkedAt, stale: snapshot.stale, byteCost: snapshot.byteCost)
        touchRange(key)
        while rangeSnapshotOrder.count > 3 || rangeSnapshots.values.reduce(0, { $0 + $1.byteCost }) > budget {
            guard let victim = rangeSnapshotOrder.firstIndex(where: { $0 != rangeIdentity }) else { break }
            rangeSnapshots.removeValue(forKey: rangeSnapshotOrder.remove(at: victim))
        }
    }

    private func touchRange(_ key: CalendarRangeIdentity) {
        rangeSnapshotOrder.removeAll { $0 == key }
        rangeSnapshotOrder.append(key)
    }

    func restoreCachedCalendars(_ records: [AccountRecord], lifecycle: Int) async {
        guard let app, let store else { return }
        var display: [CalendarDisplayCalendar] = []
        for record in records {
            guard lifecycle == lifecycleRevision, let service = app.calendarService(for: record.id) else { continue }
            await stoppingEngines[record.id]?.value
            guard lifecycle == lifecycleRevision else { return }
            services[record.id] = service
            if engines[record.id] == nil {
                engines[record.id] = CalendarSyncEngine(accountID: record.id, service: service, store: store)
            }
            let entries = (try? await store.calendars(accountID: record.id)) ?? []
            let stored = (try? await app.calendarPreferences(accountID: record.id)) ?? []
            guard lifecycle == lifecycleRevision else { return }
            for entry in entries where entry.deleted != true {
                let preference = stored.first { $0.calendarID == entry.id }
                    ?? CalendarPreferences(accountID: record.id, calendarID: entry.id,
                        visible: entry.hidden != true, notificationsEnabled: false)
                preferences[CalendarDisplayCalendar.key(accountID: record.id, calendarID: entry.id)] = preference
                display.append(CalendarDisplayCalendar(entry: entry, accountID: record.id,
                    accountName: record.displayName ?? record.email, isVisible: preference.visible,
                    aiAccess: CalendarAIAccess(rawValue: preference.assistantAccess.rawValue) ?? .off,
                    useForScheduling: preference.includeInScheduling,
                    canManage: record.enabledFeatures.contains(AccountFeature.calendarManagement.rawValue),
                    canShare: record.enabledFeatures.contains(AccountFeature.calendarSharing.rawValue),
                    notificationsEnabled: preference.notificationsEnabled))
            }
        }
        guard lifecycle == lifecycleRevision else { return }
        publishCalendars(display)
        await reloadOccurrences(refresh: false)
    }
}
