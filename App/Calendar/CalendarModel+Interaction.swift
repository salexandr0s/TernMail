import Foundation
import GmailAPI
import MailStore

extension CalendarModel {
    /// Moves the shown period: a day, week, month or year depending on the mode.
    func shift(periods: Int) {
        date = calendar.date(byAdding: mode.component, value: periods, to: date) ?? date
    }

    /// Moves the date inside the view: by day in Day and Week, by week in Month, by month in Year.
    func shift(steps: Int) {
        date = calendar.date(byAdding: mode.stepComponent, value: steps, to: date) ?? date
    }

    /// Selects the event before or after the current one on its day. Without a
    /// selection, ↓ takes the day's first event and ↑ its last.
    @discardableResult
    func selectAdjacentEvent(_ offset: Int) -> Bool {
        let selected = events.first { $0.id == selectedEventID }
        let day = selected?.start ?? date
        let candidates = CalendarLayout.events(events, on: day, calendar: calendar)
        guard !candidates.isEmpty else { return false }
        guard let selected, let index = candidates.firstIndex(where: { $0.id == selected.id }) else {
            selectedEventID = (offset > 0 ? candidates.first : candidates.last)?.id
            return true
        }
        let next = min(candidates.count - 1, max(0, index + offset))
        selectedEventID = candidates[next].id
        return true
    }

    /// Puts the change on the window's undo stack, so Edit ▸ Undo shows `name`.
    /// Undo goes through `undo()`, which still asks before notifying guests.
    func registerUndo(named name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in Task { await model.undo() } }
        undoManager.setActionName(name)
    }

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
