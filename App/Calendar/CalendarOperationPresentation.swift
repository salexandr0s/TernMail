import GmailAPI
import MailStore

struct CalendarOperationPresentation {
    let operation: CalendarOperation

    var event: GoogleCalendarEvent? {
        if operation.status == .completed, let result = operation.resultEvent { return result }
        switch operation.mutation {
        case .create(let event), .importEvent(let event): return event
        case .importSeries(let master, _): return master
        case .splitSeries(_, _, _, let following, _): return following
        case .update(_, let fields, _):
            guard var event = operation.beforeEvent else { return nil }
            for (key, value) in fields { event.rawValue[key] = value == .null ? nil : value }
            return event
        case .deleteFollowing(_, _, let start):
            guard var event = operation.beforeEvent ?? operation.resultEvent else { return nil }
            event.start = start
            return event
        default: return operation.beforeEvent ?? operation.resultEvent
        }
    }

    var title: String {
        let name = event?.title ?? operation.beforeEvent?.title ?? "event"
        switch operation.mutation {
        case .create: return "Create \(name)"
        case .importEvent, .importSeries: return "Import \(name)"
        case .update: return "Update \(name)"
        case .delete: return "Delete \(name)"
        case .respond: return "Reply to \(name)"
        case .move: return "Move \(name)"
        case .splitSeries: return "Change following events: \(name)"
        case .deleteFollowing: return "Delete following events: \(name)"
        }
    }
}
