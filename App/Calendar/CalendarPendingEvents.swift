import Foundation
import GmailAPI
import MailStore

/// Queued changes are drawn from their durable receipt while the server is
/// unavailable. A reviewed source snapshot also works after changing the visible
/// date window or reopening the app. Failed writes show the cached server value.
enum CalendarPendingEvents {
    static func blocksEditing(_ operation: CalendarOperation, event: CalendarDisplayEvent) -> Bool {
        guard [.queued, .running, .failed, .conflicted].contains(operation.status),
              operation.accountID == event.accountID else { return false }
        if case .move(let id, let destination, _) = operation.mutation,
           destination == event.calendarID, id == event.event.id { return true }
        guard operation.calendarID == event.calendarID else { return false }
        let id = operation.mutation.eventID
        return id == event.event.id || (id != nil && id == event.event.recurringEventId)
            || event.event.id == pendingID(operation)
    }

    static func project(_ events: [CalendarDisplayEvent], operations: [CalendarOperation],
                        calendars: [CalendarDisplayCalendar], interval: DateInterval, calendar: Calendar) -> [CalendarDisplayEvent] {
        var result = events
        for operation in operations.sorted(by: { $0.createdAt < $1.createdAt })
            where operation.status == .queued || operation.status == .running {
            guard let owner = calendars.first(where: {
                $0.accountID == operation.accountID && $0.calendarID == operation.calendarID && $0.entry.canReadDetails
            }) else { continue }
            func matches(_ event: CalendarDisplayEvent, id: String, includeSeries: Bool = false) -> Bool {
                event.calendarKey == owner.id && (event.event.id == id || (includeSeries && event.event.recurringEventId == id))
            }
            func display(_ event: GoogleCalendarEvent, in owner: CalendarDisplayCalendar) -> CalendarDisplayEvent {
                CalendarDisplayEvent(event: event, accountID: owner.accountID, calendarID: owner.calendarID,
                    colorHex: owner.colorHex, isPending: true, canEdit: false, fallbackTimeZoneID: calendar.timeZone.identifier)
            }
            func source(_ id: String) -> GoogleCalendarEvent? {
                operation.beforeEvent ?? result.first(where: { matches($0, id: id) })?.event
            }
            func replace(_ event: GoogleCalendarEvent, in owner: CalendarDisplayCalendar) {
                result.removeAll { $0.calendarKey == owner.id && $0.event.id == event.id }
                if owner.isVisible { result.append(display(event, in: owner)) }
            }
            switch operation.mutation {
            case .create(var event), .importEvent(var event):
                event.id = pendingID(operation)
                replace(event, in: owner)
            case .importSeries(var master, _):
                master.id = pendingID(operation)
                replace(master, in: owner)
            case .update(let id, let fields, _):
                if var event = source(id), event.id == id {
                    let isSeriesMaster = event.recurrence?.isEmpty == false && event.recurringEventId == nil
                    for (key, value) in fields { event.rawValue[key] = value == .null ? nil : value }
                    // Occurrence updates have exact dates. A series master's
                    // anchor is not a replacement for every expanded occurrence.
                    if !isSeriesMaster {
                        replace(event, in: owner)
                    }
                }
                for index in result.indices where matches(result[index], id: id, includeSeries: true) {
                    result[index].isPending = true; result[index].canEdit = false
                }
            case .delete(let id, _):
                result.removeAll { matches($0, id: id, includeSeries: true) }
            case .deleteFollowing(let id, _, let originalStart):
                if let boundary = originalStart.resolvedDate(fallbackTimeZone: calendar.timeZone) {
                    result.removeAll {
                        matches($0, id: id, includeSeries: true)
                            && ($0.event.originalStartTime?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? $0.start) >= boundary
                    }
                }
            case .move(let id, let destination, _):
                let event = source(id)
                result.removeAll { matches($0, id: id) }
                if let event, let target = calendars.first(where: {
                    $0.accountID == operation.accountID && $0.calendarID == destination && $0.entry.canReadDetails
                }) { replace(event, in: target) }
            case .respond(let id, _, _):
                for index in result.indices where matches(result[index], id: id) {
                    result[index].isPending = true; result[index].canEdit = false
                }
            case .splitSeries(let id, _, let originalStart, _, _):
                let boundary = originalStart.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? .distantPast
                for index in result.indices where matches(result[index], id: id, includeSeries: true)
                    && (result[index].event.originalStartTime?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? result[index].start) >= boundary {
                    result[index].isPending = true; result[index].canEdit = false
                }
            }
        }
        let visible = Set(calendars.filter(\.isVisible).map(\.id))
        return result.filter { visible.contains($0.calendarKey) && !$0.event.isCancelled && $0.start < interval.end && $0.end > interval.start }
            .map { event in
                var value = event
                if operations.contains(where: { blocksEditing($0, event: event) }) { value.canEdit = false }
                return value
            }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    private static func pendingID(_ operation: CalendarOperation) -> String {
        if case .create = operation.mutation { return operation.id.replacingOccurrences(of: "-", with: "") }
        return "pending-" + operation.id
    }
}
