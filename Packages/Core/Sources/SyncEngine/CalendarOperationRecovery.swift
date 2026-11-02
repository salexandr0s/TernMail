import Foundation
import GmailAPI
import MailStore

/// A read-only review of the exact remote versions a recovery would affect.
/// The queue keeps its original identity and checkpoints throughout recovery.
public struct CalendarOperationRecovery: Sendable, Equatable, Identifiable {
    public var id: String { operation.id }
    public let operation: CalendarOperation
    public let currentEvents: [GoogleCalendarEvent]
    public let isAlreadyApplied: Bool
    public let canEdit: Bool
    public let canDiscard: Bool
    public let blockedReason: String?
    public var reviewedMutation: CalendarMutation { resumed.mutation }
    public var completedStep: Int { resumed.completedStep }
    public var plannedRecurrence: [String]? { resumed.preparedRecurrence }
    let resumed: CalendarOperation
}

extension CalendarSyncEngine {
    public func reviewRecovery(operationID: String) async throws -> CalendarOperationRecovery {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard let operation = try await store.operation(accountID: accountID, id: operationID),
              [.failed, .conflicted].contains(operation.status) else { throw CalendarEngineError.invalidOperation }
        guard try await calendar(operation.calendarID).canWrite else { throw CalendarEngineError.permissionDenied }
        return try await recovery(operation, epoch: epoch)
    }

    /// A fresh read must match the displayed review. Subsequent writes still use
    /// those reviewed ETags, so a change after this check produces another review.
    public func resumeRecovery(_ review: CalendarOperationRecovery) async throws {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard review.blockedReason == nil else { throw CalendarEngineError.invalidOperation }
        try await validateRecovery(review, epoch: epoch)
        var operation = review.resumed
        operation.status = review.isAlreadyApplied ? .completed : .queued
        operation.errorMessage = nil; operation.updatedAt = .now
        try await store.recoverOperation(expected: review.operation, with: operation)

    }

    public func discardRecovery(_ review: CalendarOperationRecovery) async throws {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard review.canDiscard else { throw CalendarEngineError.invalidOperation }
        try await validateRecovery(review, epoch: epoch)
        var operation = review.operation
        operation.status = .cancelled; operation.updatedAt = .now
        try await store.recoverOperation(expected: review.operation, with: operation)
    }

    @discardableResult
    public func reviseRecovery(_ review: CalendarOperationRecovery, mutation: CalendarMutation) async throws -> CalendarOperation {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard review.canEdit else { throw CalendarEngineError.invalidOperation }
        try Self.validate(mutation)
        try await validateRecovery(review, epoch: epoch)
        // Preserve the action's kind, target and identity. In particular an
        // attempted create must never acquire a second idempotency identity.
        switch (review.resumed.mutation, mutation) {
        case (.create, .create), (.importEvent, .importEvent), (.importSeries, .importSeries): break
        case (.update(let id, _, let etag), .update(let newID, _, let newETag)) where id == newID && etag == newETag: break
        case (.splitSeries(let id, let etag, let start, _, _), .splitSeries(let newID, let newETag, let newStart, _, _))
            where id == newID && etag == newETag && start == newStart: break
        default: throw CalendarEngineError.invalidOperation
        }
        var operation = review.resumed
        operation.mutation = mutation; operation.status = .queued; operation.errorMessage = nil; operation.updatedAt = .now
        operation.preparedMutation = nil; operation.preparedRecurrence = nil; operation.affectedEventVersions = [:]
        operation.resultEvent = nil
        try await store.recoverOperation(expected: review.operation, with: operation)
        return operation
    }

    private func validateRecovery(_ review: CalendarOperationRecovery, epoch: Int) async throws {
        guard review.operation.accountID == accountID,
              try await store.operation(accountID: accountID, id: review.id) == review.operation,
              try await calendar(review.operation.calendarID).canWrite else { throw CalendarEngineError.invalidOperation }
        guard try await recovery(review.operation, epoch: epoch) == review else { throw CalendarEngineError.conflict }
        try checkpoint(epoch)
    }

    private func recovery(_ original: CalendarOperation, epoch: Int) async throws -> CalendarOperationRecovery {
        var operation = original
        var events: [GoogleCalendarEvent] = []
        var applied = false
        var editable = false
        var discardable = false
        var blockedReason: String?
        let calendarID = operation.calendarID
        switch operation.mutation {
        case .create:
            let id = operation.id.replacingOccurrences(of: "-", with: "")
            if let current = try await optionalFetch(calendarID: calendarID, eventID: id, epoch: epoch) {
                events.append(current)
                applied = Self.marker(of: current) == operation.id
                if applied { operation.resultEvent = current }
                else { blockedReason = "An existing event uses this request's identity. Refresh the review before continuing." }
            } else if operation.hasUncertainOutcome == false {
                editable = true; discardable = true
            }
            // An uncertain create may still arrive. Only definitively rejected
            // creates can change their payload or be cancelled.
        case .importEvent(let event), .importSeries(let event, _):
            let found = try await collectEvents(calendarID: calendarID, query: .init(iCalUID: event.iCalUID), epoch: epoch).events
                .filter { !$0.isCancelled && $0.recurringEventId == nil }.sorted { $0.id < $1.id }
            events += found
            let imported = found.first { Self.marker(of: $0) == operation.id } ?? (found.count == 1 ? found.first : nil)
            if case .importSeries(_, let exceptions) = operation.mutation, !exceptions.isEmpty, let imported {
                guard Self.marker(of: imported) == operation.id else {
                    blockedReason = "This calendar already has a series with the same identity. Its exceptions will be kept. Cancel this import to leave that series as it is."
                    discardable = operation.completedStep == 0 && operation.hasUncertainOutcome == false
                    break
                }
                operation.resultEvent = imported
                operation.completedStep = max(1, operation.completedStep)
                try await reviewImportedExceptions(exceptions, operation: &operation, events: &events, epoch: epoch)
                applied = operation.completedStep >= exceptions.count + 1
            } else if let imported {
                applied = true; operation.resultEvent = imported
            } else if found.isEmpty, operation.completedStep == 0 {
                editable = operation.hasUncertainOutcome == false
                discardable = editable
            } else if found.count > 1 {
                blockedReason = "Several existing events share this import's identity. Cancel the request and review those events before importing again."
                discardable = operation.completedStep == 0 && operation.hasUncertainOutcome == false
            }
        case .move(let id, let destination, _):
            guard try await calendar(destination).canWrite else { throw CalendarEngineError.permissionDenied }
            let source = try await optionalFetch(calendarID: calendarID, eventID: id, epoch: epoch)
            if let before = operation.resultEvent, let uid = before.iCalUID {
                let moved = try await collectEvents(calendarID: destination, query: .init(iCalUID: uid), epoch: epoch).events
                    .filter { !$0.isCancelled && $0.originalStartTime == before.originalStartTime }.sorted { $0.id < $1.id }
                events += moved
                if moved.count == 1, source == nil || source?.isCancelled == true {
                    applied = true; operation.resultEvent = moved[0]
                }
            }
            if !applied {
                guard let current = source, !current.isCancelled else {
                    blockedReason = "The source event is gone, but its destination could not be confirmed. Refresh the review to check again."
                    break
                }
                events.insert(current, at: 0)
                operation.mutation = .move(eventID: id, destination: destination, etag: current.etag)
                discardable = operation.hasUncertainOutcome == false
            }
        case .update(let id, let fields, _):
            let current = try await fetch(calendarID: calendarID, eventID: id, epoch: epoch)
            events.append(current)
            applied = Self.marker(of: current) == operation.id
            operation.resultEvent = applied ? current : nil
            operation.mutation = .update(eventID: id, fields: fields, etag: current.etag)
            editable = !applied; discardable = !applied
        case .respond(let id, let status, _):
            let current = try await fetch(calendarID: calendarID, eventID: id, epoch: epoch)
            events.append(current)
            applied = current.attendees?.first { $0.isSelf == true }?.responseStatus == status
            operation.resultEvent = applied ? current : nil
            operation.mutation = .respond(eventID: id, status: status, etag: current.etag)
            discardable = !applied
        case .delete(let id, _):
            if let current = try await optionalFetch(calendarID: calendarID, eventID: id, epoch: epoch), !current.isCancelled {
                events.append(current); operation.mutation = .delete(eventID: id, etag: current.etag); discardable = true
            } else { applied = true; operation.resultEvent = nil }
        case .splitSeries, .deleteFollowing:
            do {
                applied = try await reviewFollowing(operation: &operation, events: &events, epoch: epoch)
            } catch let error as CalendarEngineError where [.unsupportedRecurrence, .invalidEvent].contains(error) {
                guard original.completedStep == 0, !events.isEmpty else { throw error }
                blockedReason = error.localizedDescription
            }
            let hasPreparedPlan = original.preparedMutation != nil || original.preparedRecurrence != nil
            editable = !applied && operation.completedStep == 0 && !hasPreparedPlan
            if case .deleteFollowing = operation.mutation { editable = false }
            discardable = !applied && operation.completedStep == 0 && !hasPreparedPlan && original.hasUncertainOutcome == false
        }
        return CalendarOperationRecovery(operation: original, currentEvents: events, isAlreadyApplied: applied,
            canEdit: editable, canDiscard: discardable, blockedReason: blockedReason, resumed: operation)
    }

    private func reviewImportedExceptions(_ exceptions: [GoogleCalendarEvent], operation: inout CalendarOperation,
                                          events: inout [GoogleCalendarEvent], epoch: Int) async throws {
        guard let master = operation.resultEvent else { throw CalendarEngineError.invalidOperation }
        for index in exceptions.indices where operation.completedStep <= index + 1 {
            let exception = exceptions[index]
            let instance: GoogleCalendarEvent
            if index + 1 == operation.completedStep, case .update(let id, _, _) = operation.preparedMutation {
                instance = try await fetch(calendarID: operation.calendarID, eventID: id, epoch: epoch)
            } else {
                guard let start = exception.originalStartTime, let date = start.resolvedDate() else { throw CalendarEngineError.invalidEvent }
                let instances = try await collectInstances(calendarID: operation.calendarID, eventID: master.id,
                    query: .init(timeMin: date.addingTimeInterval(-86400), timeMax: date.addingTimeInterval(86400)), epoch: epoch)
                guard let found = instances.first(where: { Self.sameOccurrence($0.originalStartTime, start) }) else { throw CalendarEngineError.conflict }
                instance = found
            }
            events.append(instance)
            operation.affectedEventVersions[instance.id] = instance.etag ?? ""
            if index + 1 == operation.completedStep {
                if Self.marker(of: instance) == operation.id + "-exception-\(index)" || (exception.isCancelled && instance.isCancelled) {
                    operation.completedStep = index + 2; operation.preparedMutation = nil
                } else if case .update(let id, let fields, _) = operation.preparedMutation {
                    operation.preparedMutation = .update(eventID: id, fields: fields, etag: instance.etag)
                }
            }
        }
    }

    private func reviewFollowing(operation: inout CalendarOperation, events: inout [GoogleCalendarEvent], epoch: Int) async throws -> Bool {
        let id: String
        let originalStart: CalendarDateTime
        let following: GoogleCalendarEvent?
        switch operation.mutation {
        case .splitSeries(let value, _, let start, let event, _): id = value; originalStart = start; following = event
        case .deleteFollowing(let value, _, let start): id = value; originalStart = start; following = nil
        default: throw CalendarEngineError.invalidOperation
        }
        if following != nil {
            let newID = operation.id.replacingOccurrences(of: "-", with: "") + "a"
            if let saved = try await optionalFetch(calendarID: operation.calendarID, eventID: newID, epoch: epoch) {
                events.append(saved)
                if Self.marker(of: saved) == operation.id { operation.resultEvent = saved; return true }
            }
        }
        guard let current = try await optionalFetch(calendarID: operation.calendarID, eventID: id, epoch: epoch), !current.isCancelled else {
            guard following == nil else { throw CalendarEngineError.conflict }
            operation.completedStep = -1; operation.resultEvent = nil; return true
        }
        events.append(current)
        if following != nil, Self.marker(of: current) == operation.id { operation.resultEvent = current; return true }
        if Self.marker(of: current) == operation.id + "-trim"
            || (operation.preparedRecurrence != nil && current.recurrence == operation.preparedRecurrence) {
            operation.completedStep = max(1, operation.completedStep)
        }
        if operation.completedStep == 0, operation.preparedRecurrence != nil {
            // A durable plan may have been sent already. Keep its exact split
            // and new-series payload; only review the remaining target versions.
            operation.resultEvent = current
            for eventID in operation.affectedEventVersions.keys.sorted() {
                if let exception = try await optionalFetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch), !exception.isCancelled {
                    events.append(exception); operation.affectedEventVersions[eventID] = exception.etag ?? ""
                }
            }
            return false
        }
        if operation.completedStep == 0 {
            let entry = try await calendar(operation.calendarID)
            let zone = entry.timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            guard let start = current.start, let beginning = start.resolvedDate(fallbackTimeZone: zone),
                  let split = originalStart.resolvedDate(fallbackTimeZone: zone) else { throw CalendarEngineError.invalidEvent }
            operation.resultEvent = current
            if let following {
                operation.mutation = .splitSeries(eventID: id, etag: current.etag, originalStart: originalStart,
                    followingEvent: following, resetExceptionsConfirmed: true)
            } else { operation.mutation = .deleteFollowing(eventID: id, etag: current.etag, originalStart: originalStart) }
            if split <= beginning {
                operation.resultEvent = nil; operation.preparedMutation = nil; operation.preparedRecurrence = nil
                return false
            }
            let partition = try CalendarRecurrencePartition(lines: current.recurrence ?? [], start: start, split: originalStart,
                timeZone: zone, preservingSchedule: following?.recurrence == current.recurrence)
            operation.preparedRecurrence = partition.before
            let exceptions = try await futureExceptions(calendarID: operation.calendarID, eventID: id, from: split)
                .sorted { $0.id < $1.id }
            operation.affectedEventVersions = Dictionary(uniqueKeysWithValues: exceptions.map { ($0.id, $0.etag ?? "") })
            events += exceptions
            if var new = following {
                new.id = operation.id.replacingOccurrences(of: "-", with: "") + "a"
                new.iCalUID = nil; new.recurringEventId = nil; new.originalStartTime = nil
                new.etag = nil; new.organizer = nil; new.creator = nil
                if new.recurrence == current.recurrence {
                    guard partition.futureExclusionCount == 0 || new.start?.resolvedDate(fallbackTimeZone: zone) == split else {
                        throw CalendarEngineError.unsupportedRecurrence
                    }
                    new.recurrence = partition.following.isEmpty ? nil : partition.following
                } else if let lines = new.recurrence, !lines.isEmpty {
                    new.recurrence = try CalendarRecurrencePartition.reviewedFollowing(lines, split: originalStart, timeZone: zone)
                }
                operation.preparedMutation = .create(new)
            }
        } else {
            // Never re-partition an already trimmed series or reset its checkpoint.
            let ids = operation.affectedEventVersions.keys.sorted()
            for (index, eventID) in ids.enumerated() where operation.completedStep <= index + 1 {
                if let current = try await optionalFetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch), !current.isCancelled {
                    events.append(current); operation.affectedEventVersions[eventID] = current.etag ?? ""
                } else if operation.completedStep == index + 1 { operation.completedStep = index + 2 }
            }
            if following == nil, operation.completedStep >= ids.count + 1 { operation.resultEvent = current; return true }
        }
        return false
    }
}
