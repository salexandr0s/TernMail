import Foundation
import GmailAPI
import MailStore

extension CalendarSyncEngine {
    func importSeries(master: GoogleCalendarEvent, exceptions: [GoogleCalendarEvent],
                       operation: inout CalendarOperation, epoch: Int) async throws -> GoogleCalendarEvent {
        if operation.completedStep == 0 {
            let imported = try await importEvent(master, calendarID: operation.calendarID, marker: operation.id, epoch: epoch)
            // A matching UID is enough to prevent duplicates, but never enough
            // authority to overwrite another event's existing exceptions.
            guard exceptions.isEmpty || Self.marker(of: imported) == operation.id else { throw CalendarEngineError.conflict }
            operation.resultEvent = imported; operation.completedStep = 1
            try await store.saveOperation(operation)
        }
        guard let imported = operation.resultEvent else { throw CalendarEngineError.invalidOperation }
        for index in exceptions.indices where operation.completedStep <= index + 1 {
            let exception = exceptions[index]
            if operation.preparedMutation == nil {
                guard let original = exception.originalStartTime, let date = original.resolvedDate() else { throw CalendarEngineError.invalidEvent }
                let instances = try await collectInstances(calendarID: operation.calendarID, eventID: imported.id,
                    query: .init(timeMin: date.addingTimeInterval(-86400), timeMax: date.addingTimeInterval(86400)), epoch: epoch)
                guard let instance = instances.first(where: { Self.sameOccurrence($0.originalStartTime, original) }) else { throw CalendarEngineError.conflict }
                var fields = exception.writableFields
                for key in ["id", "iCalUID", "recurrence", "attendees", "organizer", "creator"] { fields.removeValue(forKey: key) }
                if exception.isCancelled { fields = ["status": .string("cancelled")] }
                operation.preparedMutation = .update(eventID: instance.id, fields: fields, etag: instance.etag)
                try await store.saveOperation(operation)
            }
            guard case .update(let id, let fields, let etag) = operation.preparedMutation else { throw CalendarEngineError.invalidOperation }
            _ = try await patch(eventID: id, calendarID: operation.calendarID, fields: fields, etag: etag,
                marker: operation.id + "-exception-\(index)", sendUpdates: "none", epoch: epoch)
            operation.completedStep = index + 2; operation.preparedMutation = nil
            try checkpoint(epoch)
            try await store.saveOperation(operation)
        }
        return imported
    }

    func split(eventID: String, etag: String?, originalStart: CalendarDateTime, following: GoogleCalendarEvent,
               confirmed: Bool, operation: inout CalendarOperation, epoch: Int) async throws -> GoogleCalendarEvent {
        let entry = try await calendar(operation.calendarID)
        let zone = entry.timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        guard let splitDate = originalStart.resolvedDate(fallbackTimeZone: zone) else { throw CalendarEngineError.invalidEvent }
        if operation.preparedMutation == nil {
            let master = try await fetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch)
            try Self.checkETag(etag, current: master)
            guard let start = master.start, let beginning = start.resolvedDate(fallbackTimeZone: zone) else { throw CalendarEngineError.invalidEvent }
            if splitDate <= beginning {
                return try await patch(eventID: eventID, calendarID: operation.calendarID,
                    fields: following.changedFields(from: master), etag: etag, marker: operation.id,
                    sendUpdates: operation.sendUpdates, epoch: epoch)
            }
            let partition = try CalendarRecurrencePartition(lines: master.recurrence ?? [], start: start,
                split: originalStart, timeZone: zone, preservingSchedule: following.recurrence == master.recurrence)
            let exceptions = try await futureExceptions(calendarID: operation.calendarID, eventID: eventID, from: splitDate)
            guard exceptions.isEmpty || confirmed else { throw CalendarEngineError.exceptionsNeedReview }
            var new = following
            new.id = operation.id.replacingOccurrences(of: "-", with: "") + "a"
            new.iCalUID = nil; new.recurringEventId = nil; new.originalStartTime = nil
            new.etag = nil; new.organizer = nil; new.creator = nil
            if new.recurrence == master.recurrence {
                // Explicit exclusions are absolute slots. Moving the schedule
                // would require remapping them, never silently ignoring them.
                guard partition.futureExclusionCount == 0 || new.start?.resolvedDate(fallbackTimeZone: zone) == splitDate else {
                    throw CalendarEngineError.unsupportedRecurrence
                }
                new.recurrence = partition.following.isEmpty ? nil : partition.following
            } else if let lines = new.recurrence, !lines.isEmpty {
                new.recurrence = try CalendarRecurrencePartition.reviewedFollowing(lines, split: originalStart, timeZone: zone)
            }
            operation.preparedMutation = .create(new)
            operation.preparedRecurrence = partition.before
            operation.resultEvent = master
            operation.affectedEventVersions = Dictionary(uniqueKeysWithValues: exceptions.map { ($0.id, $0.etag ?? "") })
            try await store.saveOperation(operation)
        }
        try await trimAndRemoveExceptions(eventID: eventID, originalStart: originalStart, operation: &operation, epoch: epoch)
        guard case .create(let new) = operation.preparedMutation else { throw CalendarEngineError.invalidOperation }
        return try await create(new, calendarID: operation.calendarID, marker: operation.id, sendUpdates: operation.sendUpdates, epoch: epoch)
    }

    func deleteFollowing(eventID: String, etag: String?, originalStart: CalendarDateTime,
                          operation: inout CalendarOperation, epoch: Int) async throws -> GoogleCalendarEvent? {
        let entry = try await calendar(operation.calendarID)
        let zone = entry.timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        guard let splitDate = originalStart.resolvedDate(fallbackTimeZone: zone) else { throw CalendarEngineError.invalidEvent }
        if operation.resultEvent == nil {
            guard let master = try await optionalFetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch) else {
                operation.completedStep = -1; return nil
            }
            try Self.checkETag(etag, current: master)
            guard let start = master.start, let beginning = start.resolvedDate(fallbackTimeZone: zone) else { throw CalendarEngineError.invalidEvent }
            if splitDate <= beginning {
                try await remove(eventID: eventID, calendarID: operation.calendarID, etag: etag,
                                 sendUpdates: operation.sendUpdates, epoch: epoch)
                operation.completedStep = -1
                return nil
            }
            let partition = try CalendarRecurrencePartition(lines: master.recurrence ?? [], start: start,
                split: originalStart, timeZone: zone, preservingSchedule: false)
            let exceptions = try await futureExceptions(calendarID: operation.calendarID, eventID: eventID, from: splitDate)
            operation.resultEvent = master
            operation.preparedRecurrence = partition.before
            operation.affectedEventVersions = Dictionary(uniqueKeysWithValues: exceptions.map { ($0.id, $0.etag ?? "") })
            try await store.saveOperation(operation)
        }
        try await trimAndRemoveExceptions(eventID: eventID, originalStart: originalStart, operation: &operation, epoch: epoch)
        return try await fetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch)
    }

    private func trimAndRemoveExceptions(eventID: String, originalStart: CalendarDateTime,
                                          operation: inout CalendarOperation, epoch: Int) async throws {
        guard let original = operation.resultEvent else { throw CalendarEngineError.invalidOperation }
        if operation.completedStep == 0 {
            // Old pending operations predate the durable recurrence partition.
            if operation.preparedRecurrence == nil {
                let entry = try await calendar(operation.calendarID)
                let zone = entry.timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
                guard let start = original.start else { throw CalendarEngineError.invalidEvent }
                operation.preparedRecurrence = try CalendarRecurrencePartition(lines: original.recurrence ?? [],
                    start: start, split: originalStart, timeZone: zone, preservingSchedule: false).before
                try await store.saveOperation(operation)
            }
            guard let recurrence = operation.preparedRecurrence else { throw CalendarEngineError.invalidOperation }
            _ = try await patch(eventID: eventID, calendarID: operation.calendarID, fields: ["recurrence": .array(recurrence.map(CalendarJSON.string))],
                etag: original.etag, marker: operation.id + "-trim", sendUpdates: operation.sendUpdates, epoch: epoch)
            operation.completedStep = 1
            try await store.saveOperation(operation)
        }
        let ids = operation.affectedEventVersions.keys.sorted()
        for (index, id) in ids.enumerated() where operation.completedStep <= index + 1 {
            let etag = operation.affectedEventVersions[id]
            guard etag?.isEmpty == false else { throw CalendarEngineError.conflict }
            try await remove(eventID: id, calendarID: operation.calendarID, etag: etag,
                             sendUpdates: operation.sendUpdates, epoch: epoch)
            operation.completedStep = index + 2
            try await store.saveOperation(operation)
        }
    }

}
