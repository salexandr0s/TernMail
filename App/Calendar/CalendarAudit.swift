#if DEBUG
import Foundation
import GmailAPI
import MailStore
import SyncEngine

/// Synthetic data for the explicit calendar UI audit. It never reads accounts,
/// credentials or events from a calendar service.
extension CalendarModel {
    func seedCalendarAudit() async {
        do {
            if store == nil { store = try CalendarStore.inMemory() }
            guard let store else { return }
            let service = CalendarAuditService(now: date)
            services["calendar-audit"] = service
            engines["calendar-audit"] = CalendarSyncEngine(accountID: "calendar-audit", service: service, store: store)
            accounts = [CalendarAccountOption(id: "calendar-audit", title: "Sample account", canManage: true, canShare: true)]
            await refreshCalendarAudit()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshCalendarAudit() async {
        guard let store, let engine = engines["calendar-audit"] else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let entries = try await engine.syncCalendars()
            let settings = try await store.preferences(accountID: "calendar-audit")
            calendars = entries.map { entry in
                let preference = settings.first { $0.calendarID == entry.id } ?? CalendarPreferences(accountID: "calendar-audit", calendarID: entry.id)
                let key = CalendarDisplayCalendar.key(accountID: "calendar-audit", calendarID: entry.id)
                preferences[key] = preference
                return CalendarDisplayCalendar(entry: entry, accountID: "calendar-audit", accountName: "Sample account",
                    isVisible: preference.visible, aiAccess: CalendarAIAccess(rawValue: preference.assistantAccess.rawValue) ?? .off,
                    useForScheduling: preference.includeInScheduling, canManage: true, canShare: true,
                    notificationsEnabled: false)
            }
            for entry in entries { try await engine.syncEvents(calendarID: entry.id) }
            try await engine.flush()
            await reloadOccurrences()
            await reloadOperations()
            statusText = "Sample calendars · changes stay in this preview"
        } catch { errorMessage = error.localizedDescription }
    }
}

actor CalendarAuditService: CalendarService {
    private var entries: [String: GoogleCalendarEntry]
    private var rows: [String: [String: GoogleCalendarEvent]]
    private var rules: [String: [CalendarACLRule]] = [:]
    private var revision = 1

    init(now: Date) {
        var personal = GoogleCalendarEntry(id: "personal", summary: "Personal", timeZone: "Europe/Vienna", accessRole: "owner", backgroundColor: "#0b8043")
        personal.primary = true
        personal.rawValue["conferenceProperties"] = .object(["allowedConferenceSolutionTypes": .array([.string("hangoutsMeet")])])
        personal.defaultReminders = [CalendarReminder(minutes: 10)]
        let work = GoogleCalendarEntry(id: "work", summary: "Studio", timeZone: "Europe/Vienna", accessRole: "owner", backgroundColor: "#4285f4")
        let shared = GoogleCalendarEntry(id: "shared", summary: "Team availability", timeZone: "Europe/Vienna", accessRole: "reader", backgroundColor: "#8e24aa")
        entries = Dictionary(uniqueKeysWithValues: [personal, work, shared].map { value in
            var entry = value; entry.etag = "audit-1"; return (entry.id, entry)
        })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna") ?? .autoupdatingCurrent
        calendar.firstWeekday = 2
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        func event(_ id: String, _ title: String, day: Int, hour: Int, minutes: Int = 60) -> GoogleCalendarEvent {
            let date = calendar.date(byAdding: .day, value: day, to: week) ?? week
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
            var event = GoogleCalendarEvent(id: id, summary: title, start: CalendarDateTime(date: start, timeZone: calendar.timeZone),
                end: CalendarDateTime(date: start.addingTimeInterval(Double(minutes) * 60), timeZone: calendar.timeZone))
            event.etag = "audit-1"; event.iCalUID = id + "@example.invalid"; event.status = "confirmed"
            event.organizer = CalendarPerson(email: "calendar@example.invalid", isSelf: true)
            return event
        }
        var breakfast = event("breakfast", "Coffee with Alex", day: 1, hour: 9, minutes: 45)
        breakfast.location = "Corner café"
        var review = event("review", "Project review", day: 2, hour: 10, minutes: 90)
        review.attendees = [CalendarAttendee(email: "alex@example.invalid", displayName: "Alex", responseStatus: "accepted")]
        review.hangoutLink = "https://meet.google.com/example"
        let overlap = event("design", "Design feedback", day: 2, hour: 11, minutes: 60)
        var planning = event("planning", "Weekly planning", day: 0, hour: 9, minutes: 30)
        planning.recurrence = ["RRULE:FREQ=WEEKLY"]
        var trip = event("trip", "Out of office", day: 3, hour: 0)
        let tripStart = calendar.date(byAdding: .day, value: 3, to: week) ?? week
        let tripEnd = calendar.date(byAdding: .day, value: 5, to: week) ?? week
        trip.start = CalendarDateTime(date: tripStart, timeZone: calendar.timeZone, allDay: true)
        trip.end = CalendarDateTime(date: tripEnd, timeZone: calendar.timeZone, allDay: true)
        let focus = event("focus", "Focus time", day: 4, hour: 14, minutes: 120)
        rows = ["personal": [breakfast.id: breakfast, trip.id: trip],
                "work": [review.id: review, overlap.id: overlap, planning.id: planning],
                "shared": [focus.id: focus]]
    }

    func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage {
        CalendarListPage(items: Array(entries.values).sorted { $0.id < $1.id }, nextSyncToken: "audit-\(revision)")
    }
    func events(calendarID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
        guard entries[calendarID] != nil else { throw GmailError.notFound }
        var values = Array(rows[calendarID, default: [:]].values)
        if query.singleEvents {
            let expandedEvents = values.filter { $0.recurringEventId == nil }.flatMap { expanded($0, query: query) }
            var byID = Dictionary(uniqueKeysWithValues: expandedEvents.map { ($0.id, $0) })
            for exception in values where exception.recurringEventId != nil { byID[exception.id] = exception }
            values = Array(byID.values)
            if let start = query.timeMin { values = values.filter { ($0.endDate ?? .distantPast) > start } }
            if let end = query.timeMax { values = values.filter { ($0.startDate ?? .distantFuture) < end } }
        }
        if let uid = query.iCalUID { values = values.filter { $0.iCalUID == uid } }
        if !query.showDeleted { values.removeAll(where: \.isCancelled) }
        return CalendarEventPage(items: values, nextSyncToken: "audit-\(revision)")
    }
    func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
        if let event = rows[calendarID]?[eventID] { return event }
        if let separator = eventID.lastIndex(of: "_"), let timestamp = TimeInterval(eventID[eventID.index(after: separator)...]),
           let master = rows[calendarID]?[String(eventID[..<separator])] {
            let date = Date(timeIntervalSince1970: timestamp)
            if let instance = expanded(master, query: CalendarEventQuery(timeMin: date, timeMax: date.addingTimeInterval(1), singleEvents: true)).first(where: { $0.id == eventID }) { return instance }
        }
        throw GmailError.notFound
    }
    func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String) async throws -> GoogleCalendarEvent {
        guard entries[calendarID]?.canWrite == true else { throw GmailError.http(status: 403, reason: "forbidden") }
        var value = event
        if value.id.isEmpty { value.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        if rows[calendarID]?[value.id] != nil { throw GmailError.http(status: 409, reason: "duplicate") }
        return store(value, in: calendarID)
    }
    func importEvent(calendarID: String, event: GoogleCalendarEvent) async throws -> GoogleCalendarEvent {
        var value = event; value.id = ""
        return try await insertEvent(calendarID: calendarID, event: value, sendUpdates: "none")
    }
    func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
        var value = try await event(calendarID: calendarID, eventID: eventID)
        if let etag, value.etag != etag { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        for (key, field) in fields { value.rawValue[key] = field == .null ? nil : field }
        return store(value, in: calendarID)
    }
    func deleteEvent(calendarID: String, eventID: String, etag: String?, sendUpdates: String) async throws {
        _ = try await patchEvent(calendarID: calendarID, eventID: eventID, fields: ["status": .string("cancelled")], etag: etag, sendUpdates: sendUpdates)
    }
    func moveEvent(calendarID: String, eventID: String, destination: String, etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent {
        let value = try await event(calendarID: calendarID, eventID: eventID)
        guard entries[destination]?.canWrite == true else { throw GmailError.http(status: 403, reason: "forbidden") }
        if let etag, value.etag != etag { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        rows[calendarID]?[eventID] = nil
        return store(value, in: destination)
    }
    func freeBusy(calendarIDs: [String], start: Date, end: Date, timeZone: String) async throws -> CalendarFreeBusyResponse {
        var result: [String: CalendarFreeBusyCalendar] = [:]
        for id in calendarIDs {
            let events = try await events(calendarID: id, query: CalendarEventQuery(timeMin: start, timeMax: end, singleEvents: true, showDeleted: false))
            result[id] = CalendarFreeBusyCalendar(busy: events.items.compactMap { event in
                guard event.transparency != "transparent", let start = event.startDate, let end = event.endDate else { return nil }
                return CalendarBusyInterval(start: start, end: end)
            })
        }
        return CalendarFreeBusyResponse(calendars: result)
    }
    func instances(calendarID: String, eventID: String, query: CalendarEventQuery) async throws -> CalendarEventPage {
        let value = try await event(calendarID: calendarID, eventID: eventID)
        return CalendarEventPage(items: expanded(value, query: query).map { rows[calendarID]?[$0.id] ?? $0 })
    }
    func calendar(calendarID: String) async throws -> GoogleCalendarEntry {
        guard let entry = entries[calendarID] else { throw GmailError.notFound }
        return entry
    }
    func patchCalendarList(calendarID: String, fields: [String: CalendarJSON], etag: String?) async throws -> GoogleCalendarEntry {
        var entry = try await calendar(calendarID: calendarID)
        if let etag, entry.etag != etag { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        for (key, field) in fields { entry.rawValue[key] = field == .null ? nil : field }
        revision += 1; entry.etag = "audit-\(revision)"; entries[calendarID] = entry; return entry
    }
    func patchCalendar(calendarID: String, fields: [String: CalendarJSON], etag: String?) async throws -> GoogleCalendarEntry {
        try await patchCalendarList(calendarID: calendarID, fields: fields, etag: etag)
    }
    func createCalendar(summary: String, timeZone: String) async throws -> GoogleCalendarEntry {
        var entry = GoogleCalendarEntry(id: UUID().uuidString, summary: summary, timeZone: timeZone, accessRole: "owner", backgroundColor: "#4285f4")
        entry.etag = "audit-\(revision)"
        entries[entry.id] = entry; rows[entry.id] = [:]; revision += 1; return entry
    }
    func insertCalendarList(calendarID: String) async throws -> GoogleCalendarEntry {
        if let entry = entries[calendarID] { return entry }
        var entry = GoogleCalendarEntry(id: calendarID, summary: calendarID, timeZone: "Europe/Vienna", accessRole: "reader", backgroundColor: "#616161")
        entry.etag = "audit-\(revision)"; entries[calendarID] = entry; rows[calendarID] = [:]; revision += 1
        return entry
    }
    func deleteCalendar(calendarID: String, etag: String?) async throws { entries[calendarID] = nil; rows[calendarID] = nil; revision += 1 }
    func deleteCalendarList(calendarID: String) async throws { try await deleteCalendar(calendarID: calendarID, etag: nil) }
    func acl(calendarID: String, pageToken: String?) async throws -> CalendarACLPage { CalendarACLPage(items: rules[calendarID] ?? []) }
    func insertACL(calendarID: String, rule: CalendarACLRule, sendNotifications: Bool) async throws -> CalendarACLRule {
        var value = rule; value.id = UUID().uuidString; value.etag = "audit-\(revision)"
        rules[calendarID, default: []].append(value); revision += 1; return value
    }
    func patchACL(calendarID: String, ruleID: String, fields: [String: CalendarJSON], etag: String?) async throws -> CalendarACLRule {
        guard let index = rules[calendarID]?.firstIndex(where: { $0.id == ruleID }), var value = rules[calendarID]?[index] else { throw GmailError.notFound }
        if let etag, value.etag != etag { throw GmailError.http(status: 412, reason: "conditionNotMet") }
        for (key, field) in fields { value.rawValue[key] = field == .null ? nil : field }
        revision += 1; value.etag = "audit-\(revision)"; rules[calendarID]?[index] = value; return value
    }
    func deleteACL(calendarID: String, ruleID: String, etag: String?) async throws { rules[calendarID]?.removeAll { $0.id == ruleID }; revision += 1 }

    private func store(_ event: GoogleCalendarEvent, in calendarID: String) -> GoogleCalendarEvent {
        var value = event; revision += 1; value.etag = "audit-\(revision)"
        rows[calendarID, default: [:]][value.id] = value; return value
    }
    private func expanded(_ event: GoogleCalendarEvent, query: CalendarEventQuery) -> [GoogleCalendarEvent] {
        guard event.recurrence?.contains(where: { $0.hasPrefix("RRULE:FREQ=WEEKLY") }) == true,
              let start = event.startDate, let end = event.endDate else { return [event] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.start?.timeZone ?? "") ?? .autoupdatingCurrent
        let lower = query.timeMin ?? start, upper = query.timeMax ?? calendar.date(byAdding: .year, value: 1, to: start) ?? start
        var current = start, result: [GoogleCalendarEvent] = []
        for _ in 0..<600 {
            if current >= upper { break }
            if current.addingTimeInterval(end.timeIntervalSince(start)) > lower {
                var occurrence = event
                occurrence.id = event.id + "_" + String(Int(current.timeIntervalSince1970))
                occurrence.recurrence = nil; occurrence.recurringEventId = event.id
                occurrence.start = CalendarDateTime(date: current, timeZone: calendar.timeZone)
                occurrence.end = CalendarDateTime(date: current.addingTimeInterval(end.timeIntervalSince(start)), timeZone: calendar.timeZone)
                occurrence.originalStartTime = occurrence.start
                result.append(occurrence)
            }
            guard let next = calendar.date(byAdding: .day, value: 7, to: current) else { break }
            current = next
        }
        return result
    }
}
#endif
