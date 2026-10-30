import Foundation
import GmailAPI
import SyncEngine

extension CalendarModel {
    /// Search a stated window instead of implying that a partial result covers
    /// every event ever created. Google expands recurring occurrences for us.
    func searchEvents() async {
        searchRevision += 1
        let revision = searchRevision
        let access = lifecycleRevision
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = []; searchStatus = ""; return }
        guard query.count <= 500 else { searchStatus = "Use a shorter search."; return }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard revision == searchRevision else { return }
        let pivot = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .year, value: -1, to: pivot),
              let end = calendar.date(byAdding: .year, value: 1, to: pivot) else { return }
        searchStatus = "Searching calendars…"
        var found: [CalendarDisplayEvent] = []
        var failures = 0
        let owners = calendars.filter { $0.isVisible && $0.entry.canReadDetails }
        for owner in owners {
            guard revision == searchRevision, access == lifecycleRevision, !Task.isCancelled else { return }
            guard let engine = engines[owner.accountID] else { failures += 1; continue }
            do {
                var matches = try await engine.searchEvents(calendarID: owner.calendarID, query: query, start: start, end: pivot)
                matches += try await engine.searchEvents(calendarID: owner.calendarID, query: query, start: pivot, end: end)
                guard revision == searchRevision, access == lifecycleRevision, !Task.isCancelled else { return }
                found += matches.filter { !$0.isCancelled }.map {
                    CalendarDisplayEvent(event: $0, accountID: owner.accountID, calendarID: owner.calendarID,
                        colorHex: owner.colorHex, canEdit: CalendarEventPermissions.canEdit($0, in: owner),
                        fallbackTimeZoneID: calendar.timeZone.identifier)
                }
            } catch {
                if Task.isCancelled { return }
                failures += 1
                found += events.filter {
                    $0.calendarKey == owner.id && [$0.event.summary, $0.event.location, $0.event.description]
                        .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
                }
            }
        }
        guard revision == searchRevision, access == lifecycleRevision, !Task.isCancelled else { return }
        await reloadOperations()
        guard revision == searchRevision, access == lifecycleRevision, !Task.isCancelled else { return }
        var ids = Set<String>()
        searchResults = found.filter { ids.insert($0.id).inserted }.map { event in
            var value = event
            if operations.contains(where: { CalendarPendingEvents.blocksEditing($0, event: event) }) { value.canEdit = false }
            return value
        }.sorted { $0.start < $1.start }
        let interval = DateIntervalFormatter()
        interval.dateStyle = .medium; interval.timeStyle = .none; interval.timeZone = calendar.timeZone
        let scope = interval.string(from: start, to: end)
        searchStatus = "\(searchResults.count) results · \(scope) · visible calendars"
            + (failures > 0 ? " · \(failures) calendars could not be searched; cached matches may be incomplete." : "")
    }
}
