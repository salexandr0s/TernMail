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
}

struct CalendarRangeSnapshot {
    let presentation: CalendarPresentationSnapshot
    let checkedAt: Date?
    let stale: Bool
    let byteCost: Int
}

private struct CalendarOwnerRange: Sendable {
    let owner: CalendarDisplayCalendar
    let result: CalendarOccurrenceResult?
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
        if let saved = rangeSnapshots[key] {
            publish(saved)
            touchRange(key)
            if let checked = saved.checkedAt, Date.now.timeIntervalSince(checked) < 60 { return }
        }
        if let activeRangeTask, activeRangeTask.key == key {
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
        rangeSnapshots.removeAll()
        rangeSnapshotOrder.removeAll()
        completedSearch = nil
        searchCompletedAt = nil
    }

    /// Synthetic fixtures and externally restored event arrays use the same
    /// preparation path as a fetched range, without accessing any service.
    func preparePresentationForCurrentEvents() async {
        let current = events
        let key = rangeIdentity
        let displayCalendar = calendar
        let interval = displayInterval
        let buildsTimeAxis = mode == .day || mode == .week
        let prepared = await Task.detached(priority: .userInitiated) {
            CalendarPresentationSnapshot(events: current, interval: interval, calendar: displayCalendar,
                buildsTimeAxis: buildsTimeAxis)
        }.value
        guard key == rangeIdentity, events == current, !Task.isCancelled else { return }
        presentation = prepared
        presentationRevision += 1
    }

    func reloadOccurrences(refresh: Bool = true, refreshIfIncomplete: Bool = false) async {
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
            let stale = loaded.contains { $0.result?.isStale != false || $0.result?.isComplete != true }
            if refreshIfIncomplete, loaded.contains(where: { $0.result?.isComplete != true }) { needsRefresh = true }
            let checkedAt = stale ? nil : loaded.compactMap { $0.result?.fetchedAt }.min() ?? Date.now
            let preparation = Task.detached(priority: .userInitiated) { () throws -> CalendarRangeSnapshot in
                var found: [CalendarDisplayEvent] = []
                for item in loaded {
                    for event in item.result?.events ?? [] where !event.isCancelled {
                        try Task.checkCancellation()
                        found.append(CalendarDisplayEvent(event: event, accountID: item.owner.accountID,
                            calendarID: item.owner.calendarID, colorHex: item.owner.colorHex,
                            canEdit: CalendarEventPermissions.canEdit(event, in: item.owner),
                            fallbackTimeZoneID: displayCalendar.timeZone.identifier))
                    }
                }
                let projected = CalendarPendingEvents.project(found, operations: pending, calendars: allCalendars,
                    interval: interval, calendar: displayCalendar)
                try Task.checkCancellation()
                let presentation = CalendarPresentationSnapshot(events: projected, interval: interval,
                    calendar: displayCalendar, buildsTimeAxis: buildsTimeAxis)
                // Includes provider strings, day-bucket copies and placement records.
                let encodedBytes = (try? JSONEncoder().encode(projected.map(\.event)).count) ?? 0
                let references = presentation.days.reduce(0) { $0 + (presentation.day($1)?.events.count ?? 0) }
                let cost = encodedBytes * 2 + projected.count * 512 + references * 512 + presentation.days.count * 256
                return CalendarRangeSnapshot(presentation: presentation, checkedAt: checkedAt,
                    stale: stale, byteCost: cost)
            }
            let snapshot = await withTaskCancellationHandler {
                try? await preparation.value
            } onCancel: { preparation.cancel() }
            guard let snapshot, revision == rangeRevision, lifecycle == lifecycleRevision,
                  key == rangeIdentity, allCalendars == calendars, !Task.isCancelled else { return }
            if pending != operations { await reloadOccurrences(refresh: false); return }
            publish(snapshot)
            remember(snapshot, for: key)
        }
        guard revision == rangeRevision, lifecycle == lifecycleRevision, !Task.isCancelled else { return }
        Task { [weak self] in
            guard let self, lifecycle == lifecycleRevision else { return }
            await reconcileEmailSourceLinks()
        }
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
                    let result = try? await engine.occurrences(calendarID: source.0.calendarID,
                        start: interval.start, end: interval.end, refresh: refresh)
                    return CalendarOwnerRange(owner: source.0, result: result)
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
        guard snapshot.byteCost <= budget else { return }
        rangeSnapshots[key] = snapshot
        touchRange(key)
        while rangeSnapshotOrder.count > 3 || rangeSnapshots.values.reduce(0, { $0 + $1.byteCost }) > budget {
            guard !rangeSnapshotOrder.isEmpty else { break }
            rangeSnapshots.removeValue(forKey: rangeSnapshotOrder.removeFirst())
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
        calendars = display
        await reloadOccurrences(refresh: false)
    }
}
