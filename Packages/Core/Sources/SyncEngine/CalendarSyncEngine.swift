import Foundation
import GmailAPI
import MailStore

public enum CalendarEngineError: Error, Sendable, Equatable, LocalizedError {
    case accessChanged, invalidRange, incompleteResponse, permissionDenied, conflict, invalidEvent
    case invalidOperation, notAnAttendee, exceptionsNeedReview, unsupportedRecurrence
    public var errorDescription: String? {
        switch self {
        case .accessChanged: "Calendar access changed. Refresh and try again."
        case .invalidRange: "Choose a valid date range of at most one year."
        case .incompleteResponse: "Google returned an incomplete calendar response. Try refreshing."
        case .permissionDenied: "This account cannot make that calendar change."
        case .conflict: "This event changed elsewhere. Review the latest version before saving."
        case .invalidEvent: "The event needs a valid start and end in the same date format."
        case .invalidOperation: "This calendar operation is no longer available."
        case .notAnAttendee: "This account is not an attendee of this invitation."
        case .exceptionsNeedReview: "Review the future exceptions before splitting this series."
        case .unsupportedRecurrence: "This recurring series needs to be edited in Google Calendar."
        }
    }
}

/// One actor owns each account's calendar requests and queued writes. Network
/// suspension never permits results from a revoked account to repopulate storage.
public actor CalendarSyncEngine {
    public nonisolated let accountID: String
    let service: any CalendarService
    let store: CalendarStore
    var isActive = true
    var accessEpoch = 0
    var isFlushing = false
    var ongoingRequests = 0
    var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(accountID: String, service: any CalendarService, store: CalendarStore) {
        self.accountID = accountID; self.service = service; self.store = store
    }

    public func stop() async {
        isActive = false; accessEpoch += 1
        guard ongoingRequests > 0 else { return }
        await withCheckedContinuation { continuation in stopWaiters.append(continuation) }
    }
    public func invalidateAccess() async { await stop() }

    func beginRequest() throws {
        try checkpoint()
        ongoingRequests += 1
    }
    func endRequest() {
        ongoingRequests -= 1
        if ongoingRequests == 0 {
            let waiters = stopWaiters; stopWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    @discardableResult
    public func syncCalendars() async throws -> [GoogleCalendarEntry] {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        var calendars: [GoogleCalendarEntry] = []
        var token: String?
        var seen = Set<String>()
        repeat {
            try checkpoint(epoch)
            let page = try await service.calendarList(pageToken: token, syncToken: nil)
            try checkpoint(epoch)
            calendars += page.items
            token = page.nextPageToken
            if let token { guard seen.insert(token).inserted, seen.count < 1000 else { throw CalendarEngineError.incompleteResponse } }
        } while token != nil
        let previous = try await store.calendars(accountID: accountID)
        try checkpoint(epoch)
        let lostAccess = previous.contains { old in
            guard let new = calendars.first(where: { $0.id == old.id && $0.deleted != true }) else { return true }
            return old.canReadDetails && old.accessRole != new.accessRole || old.canWrite && !new.canWrite
        }
        if lostAccess { accessEpoch += 1 }
        let commitEpoch = accessEpoch
        try await store.replaceCalendars(calendars, accountID: accountID)
        try checkpoint(commitEpoch)
        return calendars.filter { $0.deleted != true }
    }

    public func syncEvents(calendarID: String) async throws {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard try await calendar(calendarID).canReadDetails else { return }
        var state = try await store.syncState(accountID: accountID, calendarID: calendarID)
        for attempt in 0..<2 {
            do {
                let result = try await collectEvents(calendarID: calendarID, query: .init(syncToken: state.syncToken), epoch: epoch)
                guard let token = result.token, !token.isEmpty else { throw CalendarEngineError.incompleteResponse }
                try checkpoint(epoch)
                try await store.applyEventSync(result.events, accountID: accountID, calendarID: calendarID,
                    token: token, replacing: state.syncToken == nil, expected: state)
                return
            } catch CalendarAPIError.syncTokenExpired where attempt == 0 {
                try checkpoint(epoch)
                try await store.resetRemoteCalendar(accountID: accountID, calendarID: calendarID)
                state = try await store.syncState(accountID: accountID, calendarID: calendarID)
            } catch {
                try checkpoint(epoch)
                if Self.httpStatus(error) == 403 {
                    accessEpoch += 1
                    try await store.resetRemoteCalendar(accountID: accountID, calendarID: calendarID)
                }
                throw error
            }
        }
    }

    public func occurrences(calendarID: String, start: Date, end: Date, refresh: Bool = true) async throws -> CalendarOccurrenceResult {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        try Self.validateRange(start: start, end: end)
        let entry = try await calendar(calendarID)
        let cached = try await store.cachedOccurrences(accountID: accountID, calendarID: calendarID, start: start, end: end)
        try checkpoint(epoch)
        guard refresh else { return cached }
        let state = try await store.syncState(accountID: accountID, calendarID: calendarID)
        do {
            let events: [GoogleCalendarEvent]
            if entry.canReadDetails {
                events = try await collectEvents(calendarID: calendarID,
                    query: .init(timeMin: start, timeMax: end, singleEvents: true), epoch: epoch).events
            } else {
                try checkpoint(epoch)
                let response = try await service.freeBusy(calendarIDs: [calendarID], start: start, end: end, timeZone: entry.timeZone ?? TimeZone.current.identifier)
                try checkpoint(epoch)
                guard let result = response.calendars[calendarID], result.errors?.isEmpty != false else { throw CalendarEngineError.permissionDenied }
                events = try result.busy.map { interval in
                    guard let begin = interval.startDate, let finish = interval.endDate, finish >= begin else { throw CalendarEngineError.incompleteResponse }
                    return GoogleCalendarEvent(rawValue: [
                        "id": .string("busy-\(begin.timeIntervalSince1970)-\(finish.timeIntervalSince1970)"),
                        "summary": .string("Busy"), "start": .object(["dateTime": .string(interval.start)]),
                        "end": .object(["dateTime": .string(interval.end)]), "locked": .bool(true),
                    ])
                }
            }
            try checkpoint(epoch)
            let now = Date.now
            try await store.saveOccurrences(events, accountID: accountID, calendarID: calendarID,
                                             start: start, end: end, expected: state, at: now)
            return CalendarOccurrenceResult(events: events.filter { !$0.isCancelled }, fetchedAt: now, isStale: false, isComplete: true)
        } catch {
            try checkpoint(epoch)
            if Self.httpStatus(error) == 403 || error as? CalendarEngineError == .permissionDenied {
                accessEpoch += 1
                try await store.resetRemoteCalendar(accountID: accountID, calendarID: calendarID)
            }
            if cached.isComplete, Self.isOffline(error) {
                return CalendarOccurrenceResult(events: cached.events, fetchedAt: cached.fetchedAt, isStale: true, isComplete: true)
            }
            throw error
        }
    }

    public func readEvent(calendarID: String, eventID: String, refresh: Bool = true) async throws -> GoogleCalendarEvent {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard try await calendar(calendarID).canReadDetails else { throw CalendarEngineError.permissionDenied }
        if !refresh, let event = try await store.event(accountID: accountID, calendarID: calendarID, eventID: eventID) {
            try checkpoint(epoch)
            return event
        }
        let state = try await store.syncState(accountID: accountID, calendarID: calendarID)
        try checkpoint(epoch)
        let event: GoogleCalendarEvent
        do { event = try await service.event(calendarID: calendarID, eventID: eventID) }
        catch {
            try checkpoint(epoch)
            if Self.httpStatus(error) == 403 {
                accessEpoch += 1
                try await store.resetRemoteCalendar(accountID: accountID, calendarID: calendarID)
            }
            throw error
        }
        try checkpoint(epoch)
        try await store.cacheEvent(event, accountID: accountID, calendarID: calendarID, expected: state)
        try checkpoint(epoch)
        return event
    }

    public func searchEvents(calendarID: String, query: String, start: Date, end: Date) async throws -> [GoogleCalendarEvent] {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        try Self.validateRange(start: start, end: end)
        guard try await calendar(calendarID).canReadDetails else { throw CalendarEngineError.permissionDenied }
        return try await collectEvents(calendarID: calendarID,
            query: .init(timeMin: start, timeMax: end, query: query, singleEvents: true), epoch: epoch).events.filter { !$0.isCancelled }
    }

    public func matchInvitation(calendarID: String, iCalUID: String, originalStart: CalendarDateTime? = nil) async throws -> [GoogleCalendarEvent] {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard !iCalUID.isEmpty, try await calendar(calendarID).canReadDetails else { throw CalendarEngineError.permissionDenied }
        let events = try await collectEvents(calendarID: calendarID, query: .init(iCalUID: iCalUID), epoch: epoch).events
        guard let originalStart else { return events.filter { !$0.isCancelled && $0.recurringEventId == nil } }
        if let exact = events.first(where: { Self.sameOccurrence($0.originalStartTime, originalStart) }) { return [exact] }
        guard let master = events.first(where: { $0.recurringEventId == nil && !$0.isCancelled }), let date = originalStart.resolvedDate() else { return [] }
        return try await collectInstances(calendarID: calendarID, eventID: master.id,
            query: .init(timeMin: date.addingTimeInterval(-86400), timeMax: date.addingTimeInterval(86400)), epoch: epoch)
            .filter { Self.sameOccurrence($0.originalStartTime, originalStart) }
    }

    public func futureExceptions(calendarID: String, eventID: String, from date: Date) async throws -> [GoogleCalendarEvent] {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        let entry = try await calendar(calendarID)
        guard entry.canReadDetails else { throw CalendarEngineError.permissionDenied }
        let timeZone = entry.timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        try await syncEvents(calendarID: calendarID)
        let events = try await store.events(accountID: accountID, calendarID: calendarID).filter {
            $0.recurringEventId == eventID && ($0.originalStartTime?.resolvedDate(fallbackTimeZone: timeZone).map { $0 >= date } ?? false)
        }
        try checkpoint(epoch)
        return events
    }

    public func availability(calendarIDs: [String], start: Date, end: Date, hours: CalendarWorkingHours,
                              limit: Int = 20) async throws -> CalendarAvailabilityResult {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        try Self.validateRange(start: start, end: end)
        guard hours.isValid else { throw CalendarEngineError.invalidRange }
        let ids = Array(Set(calendarIDs)).sorted()
        guard !ids.isEmpty else { throw CalendarEngineError.invalidRange }
        var failures: [String: String] = [:]
        var busy: [CalendarBusyInterval] = []
        for offset in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[offset..<min(offset + 50, ids.count)])
            do {
                try checkpoint(epoch)
                let response = try await service.freeBusy(calendarIDs: batch, start: start, end: end, timeZone: hours.timeZoneIdentifier)
                try checkpoint(epoch)
                for id in batch {
                    guard let value = response.calendars[id], value.errors?.isEmpty != false else {
                        failures[id] = "Availability could not be checked."; continue
                    }
                    guard value.busy.allSatisfy({ $0.startDate != nil && $0.endDate != nil && ($0.endDate ?? .distantPast) >= ($0.startDate ?? .distantFuture) }) else {
                        failures[id] = "Google returned incomplete availability."; continue
                    }
                    busy += value.busy
                }
            } catch {
                try checkpoint(epoch)
                for id in batch { failures[id] = "Availability could not be checked." }
            }
        }
        return CalendarAvailabilityResult(calendarIDs: ids, timeZone: hours.timeZoneIdentifier, busy: busy,
            slots: failures.isEmpty ? CalendarAvailability.findSlots(start: start, end: end, busy: busy, hours: hours, limit: limit) : [], failures: failures)
    }

    func calendar(_ id: String) async throws -> GoogleCalendarEntry {
        guard let entry = try await store.calendars(accountID: accountID).first(where: { $0.id == id && $0.deleted != true }) else {
            throw CalendarEngineError.permissionDenied
        }
        return entry
    }

    @discardableResult
    func checkpoint(_ expected: Int? = nil) throws -> Int {
        try Task.checkCancellation()
        guard isActive, expected == nil || expected == accessEpoch else { throw CalendarEngineError.accessChanged }
        return accessEpoch
    }

    func collectEvents(calendarID: String, query original: CalendarEventQuery, epoch: Int) async throws -> (events: [GoogleCalendarEvent], token: String?) {
        var query = original
        var events: [GoogleCalendarEvent] = []
        var pages = Set<String>()
        while true {
            try checkpoint(epoch)
            let page = try await service.events(calendarID: calendarID, query: query)
            try checkpoint(epoch)
            guard page.accessRole != "freeBusyReader" || query.timeMin != nil else { throw CalendarEngineError.permissionDenied }
            events += page.items
            guard let next = page.nextPageToken else { return (events, page.nextSyncToken) }
            guard !next.isEmpty, pages.insert(next).inserted, pages.count < 1000 else { throw CalendarEngineError.incompleteResponse }
            query.pageToken = next
        }
    }

    func collectInstances(calendarID: String, eventID: String, query original: CalendarEventQuery, epoch: Int) async throws -> [GoogleCalendarEvent] {
        var query = original
        var events: [GoogleCalendarEvent] = []
        var pages = Set<String>()
        while true {
            try checkpoint(epoch)
            let page = try await service.instances(calendarID: calendarID, eventID: eventID, query: query)
            try checkpoint(epoch)
            events += page.items
            guard let next = page.nextPageToken else { return events }
            guard !next.isEmpty, pages.insert(next).inserted, pages.count < 1000 else { throw CalendarEngineError.incompleteResponse }
            query.pageToken = next
        }
    }

    static func sameOccurrence(_ lhs: CalendarDateTime?, _ rhs: CalendarDateTime) -> Bool {
        guard let lhs, lhs.isAllDay == rhs.isAllDay else { return false }
        if lhs.isAllDay { return lhs.date == rhs.date }
        guard let a = lhs.resolvedDate(), let b = rhs.resolvedDate() else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }
    static func validateRange(start: Date, end: Date) throws {
        guard start < end, end.timeIntervalSince(start) <= 366 * 86400 else { throw CalendarEngineError.invalidRange }
    }
    static func isOffline(_ error: any Error) -> Bool {
        if let error = error as? GmailError { return error.isRetryable }
        return error is URLError
    }
}
