import Foundation
import GmailAPI
import MailStore

extension CalendarModel {
    func beginNew(in range: CalendarEventRange) {
        guard range.start.timeIntervalSinceReferenceDate.isFinite,
              range.end.timeIntervalSinceReferenceDate.isFinite, range.end > range.start else {
            errorMessage = CalendarModelError.invalidEvent.localizedDescription; return
        }
        guard let owner = calendars.first(where: { $0.canWrite && $0.isVisible }) ?? calendars.first(where: \.canWrite) else {
            errorMessage = "Connect a writable Google calendar before adding an event."; return
        }
        editRevision += 1
        editor = CalendarEditorDraft(event: range.applying(to: GoogleCalendarEvent(summary: ""), calendar: calendar),
                                     calendarKey: owner.id)
    }

    /// A gesture keeps its original snapshot until release. Only that version may
    /// be committed; a refresh, revoked permission or pending edit invalidates it.
    func change(_ display: CalendarDisplayEvent, to range: CalendarEventRange) async throws {
        guard range.start.timeIntervalSinceReferenceDate.isFinite,
              range.end.timeIntervalSinceReferenceDate.isFinite, range.end > range.start else {
            throw CalendarModelError.invalidEvent
        }
        guard range != CalendarEventRange(display) else { return }
        guard display.canEdit, !display.isPending,
              let owner = calendars.first(where: { $0.id == display.calendarKey && $0.isVisible }),
              CalendarEventPermissions.canEdit(display.event, in: owner) else {
            throw CalendarModelError.readOnly
        }
        guard interactionsInFlight.insert(display.id).inserted else { return }
        defer { interactionsInFlight.remove(display.id) }
        let revision = lifecycleRevision
        await reloadOperations()
        guard revision == lifecycleRevision else { throw CalendarModelError.unavailable }
        guard let current = (events + searchResults).first(where: { $0.id == display.id }),
              current.event == display.event else { throw CalendarModelError.changed }
        guard current.canEdit, !current.isPending,
              calendars.contains(where: { $0.id == display.calendarKey && $0.canWrite && $0.isVisible }) else {
            throw CalendarModelError.readOnly
        }
        guard !operations.contains(where: { CalendarPendingEvents.blocksEditing($0, event: current) }) else {
            throw CalendarModelError.unsupported("This event has a change waiting to sync. Review it in Calendar activity before changing it again.")
        }
        let changed = range.applying(to: current.event, calendar: calendar)
        guard !changed.changedFields(from: current.event).isEmpty else { return }
        if current.isRecurring || !(current.event.attendees ?? []).isEmpty {
            edit(current, proposedEvent: changed)
        } else {
            try await save(CalendarEditorDraft(event: changed, calendarKey: current.calendarKey, source: current))
        }
    }

    func projectPendingEvents() {
        events = CalendarPendingEvents.project(events, operations: operations, calendars: calendars,
                                               interval: displayInterval, calendar: calendar)
    }

    /// Recheck the durable queue at the mutation boundary, including actions from
    /// search and editors whose displayed snapshot predates another local write.
    func validateMutationSource(_ source: CalendarDisplayEvent, replacing operationID: String? = nil) async throws {
        guard source.canEdit, !source.isPending, let owner = calendars.first(where: { $0.id == source.calendarKey }),
              CalendarEventPermissions.canEdit(source.event, in: owner) else { throw CalendarModelError.readOnly }
        let revision = lifecycleRevision
        await reloadOperations()
        guard revision == lifecycleRevision else { throw CalendarModelError.unavailable }
        guard let currentOwner = calendars.first(where: { $0.id == source.calendarKey }),
              CalendarEventPermissions.canEdit(source.event, in: currentOwner) else { throw CalendarModelError.readOnly }
        guard !operations.contains(where: { $0.id != operationID && CalendarPendingEvents.blocksEditing($0, event: source) }) else {
            throw CalendarModelError.unsupported("This event has a change waiting to sync. Review it in Calendar activity before changing it again.")
        }
    }
}

enum CalendarEventPermissions {
    static func canEdit(_ event: GoogleCalendarEvent, in calendar: CalendarDisplayCalendar) -> Bool {
        calendar.canWrite && event.rawValue["locked"] != .bool(true)
            && (event.eventType == nil || event.eventType == "default")
    }
}
