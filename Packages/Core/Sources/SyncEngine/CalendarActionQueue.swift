import Foundation
import GmailAPI
import MailStore

extension CalendarSyncEngine {
    @discardableResult
    public func propose(_ mutation: CalendarMutation, calendarID: String, sendUpdates: String = "all",
                        sourceSuggestionID: String? = nil) async throws -> CalendarOperation {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        try Self.validate(mutation)
        guard try await calendar(calendarID).canWrite else { throw CalendarEngineError.permissionDenied }
        try checkpoint(epoch)
        let operation = CalendarOperation(accountID: accountID, calendarID: calendarID,
                                          mutation: mutation, sendUpdates: sendUpdates, sourceSuggestionID: sourceSuggestionID)
        try await store.saveOperation(operation)
        return operation
    }

    @discardableResult
    public func enqueue(_ mutation: CalendarMutation, calendarID: String, sendUpdates: String = "all",
                        sourceSuggestionID: String? = nil, beforeEvent: GoogleCalendarEvent? = nil) async throws -> CalendarOperation {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        try Self.validate(mutation)
        guard try await calendar(calendarID).canWrite else { throw CalendarEngineError.permissionDenied }
        try checkpoint(epoch)
        var operation = CalendarOperation(accountID: accountID, calendarID: calendarID, mutation: mutation,
                                           sendUpdates: sendUpdates, status: .queued, sourceSuggestionID: sourceSuggestionID)
        // Retain the reviewed source in the same transaction as the queue receipt.
        // Offline UI projection must not wait for a network fetch to obtain it.
        operation.beforeEvent = beforeEvent
        return try await store.enqueueOperation(operation)
    }

    public func approve(operationID: String) async throws {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard let operation = try await store.operation(id: operationID), operation.accountID == accountID,
              operation.status == .proposed else { throw CalendarEngineError.invalidOperation }
        guard try await calendar(operation.calendarID).canWrite else { throw CalendarEngineError.permissionDenied }
        try checkpoint(epoch)
        try await store.approveOperation(accountID: accountID, id: operationID)
    }

    public func cancel(operationID: String) async throws {
        try beginRequest()
        defer { endRequest() }
        try checkpoint()
        guard try await store.cancelOperation(accountID: accountID, id: operationID) else {
            throw CalendarEngineError.invalidOperation
        }
    }

    @discardableResult
    public func revise(operationID: String, mutation: CalendarMutation, calendarID: String,
                       sendUpdates: String = "all", sourceSuggestionID: String? = nil,
                       beforeEvent: GoogleCalendarEvent? = nil) async throws -> CalendarOperation {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        try Self.validate(mutation)
        guard try await calendar(calendarID).canWrite else { throw CalendarEngineError.permissionDenied }
        let original = try await store.operation(accountID: accountID, id: operationID)
        try checkpoint(epoch)
        var replacement = CalendarOperation(accountID: accountID, calendarID: calendarID,
            mutation: mutation, sendUpdates: sendUpdates, status: .queued,
            sourceSuggestionID: sourceSuggestionID ?? original?.sourceSuggestionID)
        replacement.beforeEvent = beforeEvent
        try await store.replaceOperation(accountID: accountID, id: operationID, with: replacement)
        return replacement
    }

    public func retry(operationID: String) async throws {
        try beginRequest()
        defer { endRequest() }
        try checkpoint()
        try await store.requeueOperation(accountID: accountID, id: operationID)
    }

    /// Serial within an account; an uncertain response is reconciled on the next
    /// attempt using its resource ID, ETag and private operation marker.
    public func flush() async throws {
        try beginRequest()
        defer { endRequest() }
        let epoch = try checkpoint()
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        _ = try await syncCalendars()
        let operations = try await store.operations(accountID: accountID)
        for candidate in operations where candidate.status == .queued || candidate.status == .running {
            try checkpoint(epoch)
            guard var operation = try await store.claimOperation(accountID: accountID, id: candidate.id) else { continue }
            do {
                guard try await calendar(operation.calendarID).canWrite else { throw CalendarEngineError.permissionDenied }
                try checkpoint(epoch)
                let result = try await perform(&operation, epoch: epoch)
                try checkpoint(epoch)
                operation.status = .completed; operation.resultEvent = result; operation.errorMessage = nil; operation.updatedAt = .now
                let deleted: String?
                switch operation.mutation {
                case .delete(let id, _), .move(let id, _, _): deleted = id
                case .deleteFollowing(let id, _, _) where operation.completedStep == -1: deleted = id
                default: deleted = nil
                }
                try await store.finishOperation(operation, event: result, deletedEventID: deleted)
            } catch {
                try checkpoint(epoch)
                operation.hasUncertainOutcome = (operation.hasUncertainOutcome ?? true) || !Self.isDefiniteRejection(error)
                let conflict = error as? CalendarEngineError == .conflict || Self.httpStatus(error) == 412
                operation.status = conflict ? .conflicted : (Self.isOffline(error) ? .queued : .failed)
                operation.errorMessage = Self.message(for: error)
                if operation.completedStep > 0 { operation.errorMessage = "Some changes were saved. " + (operation.errorMessage ?? "Retry to finish.") }
                operation.updatedAt = .now
                try await store.saveOperation(operation)
                if Self.httpStatus(error) == 403 {
                    accessEpoch += 1
                    try await store.resetRemoteCalendar(accountID: accountID, calendarID: operation.calendarID)
                    break
                }
                if operation.status == .queued { break }
            }
        }
    }

    func perform(_ operation: inout CalendarOperation, epoch: Int) async throws -> GoogleCalendarEvent? {
        switch operation.mutation {
        case .update, .delete, .deleteFollowing, .respond, .move, .splitSeries:
            if operation.beforeEvent == nil, let eventID = operation.mutation.eventID {
                operation.beforeEvent = try await optionalFetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch)
                try await store.saveOperation(operation)
            }
        case .create, .importEvent, .importSeries: break
        }
        switch operation.mutation {
        case .create(var event):
            event.id = operation.id.replacingOccurrences(of: "-", with: "")
            event.iCalUID = nil
            return try await create(event, calendarID: operation.calendarID, marker: operation.id, sendUpdates: operation.sendUpdates, epoch: epoch)
        case .importEvent(let event):
            return try await importEvent(event, calendarID: operation.calendarID, marker: operation.id, epoch: epoch)
        case .importSeries(let master, let exceptions):
            return try await importSeries(master: master, exceptions: exceptions, operation: &operation, epoch: epoch)
        case .update(let eventID, let fields, let etag):
            return try await patch(eventID: eventID, calendarID: operation.calendarID, fields: fields,
                etag: etag, marker: operation.id, sendUpdates: operation.sendUpdates, epoch: epoch)
        case .delete(let eventID, let etag):
            try await remove(eventID: eventID, calendarID: operation.calendarID, etag: etag, sendUpdates: operation.sendUpdates, epoch: epoch)
            return nil
        case .deleteFollowing(let eventID, let etag, let originalStart):
            return try await deleteFollowing(eventID: eventID, etag: etag, originalStart: originalStart,
                                             operation: &operation, epoch: epoch)
        case .respond(let eventID, let status, let etag):
            let current = try await fetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch)
            guard let attendee = current.attendees?.first(where: { $0.isSelf == true }) else { throw CalendarEngineError.notAnAttendee }
            if attendee.responseStatus == status { return current }
            return try await patch(eventID: eventID, calendarID: operation.calendarID, fields: [
                "attendees": .array([.object(["email": .string(attendee.email), "responseStatus": .string(status)])]),
                "attendeesOmitted": .bool(true),
            ], etag: etag, marker: operation.id, sendUpdates: operation.sendUpdates, epoch: epoch)
        case .move(let eventID, let destination, let etag):
            guard try await calendar(destination).canWrite else { throw CalendarEngineError.permissionDenied }
            let source = try await optionalFetch(calendarID: operation.calendarID, eventID: eventID, epoch: epoch)
            if operation.attempts > 1, let old = operation.resultEvent, source == nil || source?.isCancelled == true {
                if let moved = try await optionalFetch(calendarID: destination, eventID: eventID, epoch: epoch), moved.iCalUID == old.iCalUID { return moved }
                if let uid = old.iCalUID {
                    let candidates = try await collectEvents(calendarID: destination, query: .init(iCalUID: uid), epoch: epoch).events
                        .filter { !$0.isCancelled && $0.originalStartTime == old.originalStartTime }
                    if candidates.count == 1 { return candidates[0] }
                }
            }
            guard let current = source else { throw CalendarEngineError.conflict }
            try Self.checkETag(etag, current: current)
            operation.resultEvent = current
            try await store.saveOperation(operation)
            try checkpoint(epoch)
            let moved = try await service.moveEvent(calendarID: operation.calendarID, eventID: eventID,
                destination: destination, etag: current.etag, sendUpdates: operation.sendUpdates)
            try checkpoint(epoch)
            return moved
        case .splitSeries(let eventID, let etag, let originalStart, let following, let confirmed):
            return try await split(eventID: eventID, etag: etag, originalStart: originalStart,
                following: following, confirmed: confirmed, operation: &operation, epoch: epoch)
        }
    }

    func fetch(calendarID: String, eventID: String, epoch: Int) async throws -> GoogleCalendarEvent {
        try checkpoint(epoch)
        let event = try await service.event(calendarID: calendarID, eventID: eventID)
        try checkpoint(epoch)
        return event
    }

    func optionalFetch(calendarID: String, eventID: String, epoch: Int) async throws -> GoogleCalendarEvent? {
        do { return try await fetch(calendarID: calendarID, eventID: eventID, epoch: epoch) }
        catch GmailError.notFound { return nil }
        catch GmailError.http(status: 410, reason: _) { return nil }
    }

    func create(_ value: GoogleCalendarEvent, calendarID: String, marker: String, sendUpdates: String, epoch: Int) async throws -> GoogleCalendarEvent {
        var event = value
        if let existing = try await optionalFetch(calendarID: calendarID, eventID: event.id, epoch: epoch) {
            guard Self.marker(of: existing) == marker else { throw CalendarEngineError.conflict }
            return existing
        }
        Self.mark(&event, marker: marker)
        try checkpoint(epoch)
        do {
            let result = try await service.insertEvent(calendarID: calendarID, event: event, sendUpdates: sendUpdates)
            try checkpoint(epoch)
            return result
        } catch GmailError.http(status: 409, reason: _) {
            let result = try await fetch(calendarID: calendarID, eventID: event.id, epoch: epoch)
            guard Self.marker(of: result) == marker else { throw CalendarEngineError.conflict }
            return result
        }
    }

    func importEvent(_ value: GoogleCalendarEvent, calendarID: String, marker: String, epoch: Int) async throws -> GoogleCalendarEvent {
        guard let uid = value.iCalUID, !uid.isEmpty else { throw CalendarEngineError.invalidEvent }
        let found = try await collectEvents(calendarID: calendarID, query: .init(iCalUID: uid), epoch: epoch).events
            .filter { !$0.isCancelled && $0.recurringEventId == nil }
        if let exact = found.first(where: { Self.marker(of: $0) == marker }) { return exact }
        if found.count == 1 { return found[0] }
        guard found.isEmpty else { throw CalendarEngineError.conflict }
        var event = value
        event.id = ""
        Self.mark(&event, marker: marker)
        try checkpoint(epoch)
        let result = try await service.importEvent(calendarID: calendarID, event: event)
        try checkpoint(epoch)
        return result
    }

    func patch(eventID: String, calendarID: String, fields: [String: CalendarJSON], etag: String?,
               marker: String, sendUpdates: String, epoch: Int) async throws -> GoogleCalendarEvent {
        let current = try await fetch(calendarID: calendarID, eventID: eventID, epoch: epoch)
        if Self.marker(of: current) == marker { return current }
        try Self.checkETag(etag, current: current)
        var fields = fields
        var extended = current.extendedProperties ?? CalendarExtendedProperties()
        if let requested = fields["extendedProperties"], requested != .null {
            extended = try requested.decoded(as: CalendarExtendedProperties.self)
        }
        var privateFields = extended.privateProperties ?? [:]
        privateFields[Self.operationKey] = marker
        extended.privateProperties = privateFields
        fields["extendedProperties"] = try CalendarJSON.encoding(extended)
        try checkpoint(epoch)
        let result = try await service.patchEvent(calendarID: calendarID, eventID: eventID, fields: fields,
            etag: current.etag, sendUpdates: sendUpdates)
        try checkpoint(epoch)
        return result
    }

    func remove(eventID: String, calendarID: String, etag: String?, sendUpdates: String, epoch: Int) async throws {
        guard let current = try await optionalFetch(calendarID: calendarID, eventID: eventID, epoch: epoch), !current.isCancelled else { return }
        try Self.checkETag(etag, current: current)
        try checkpoint(epoch)
        do { try await service.deleteEvent(calendarID: calendarID, eventID: eventID, etag: current.etag, sendUpdates: sendUpdates) }
        catch GmailError.notFound { return }
        catch GmailError.http(status: 410, reason: _) { return }
        try checkpoint(epoch)
    }

    static let operationKey = "ternOperation"
    static func marker(of event: GoogleCalendarEvent) -> String? { event.extendedProperties?.privateProperties?[operationKey] }
    static func mark(_ event: inout GoogleCalendarEvent, marker: String) {
        var extended = event.extendedProperties ?? CalendarExtendedProperties()
        var values = extended.privateProperties ?? [:]
        values[operationKey] = marker; extended.privateProperties = values; event.extendedProperties = extended
    }
    static func checkETag(_ etag: String?, current: GoogleCalendarEvent) throws {
        guard !current.isCancelled, let actual = current.etag, !actual.isEmpty else { throw CalendarEngineError.conflict }
        if let etag, actual != etag { throw CalendarEngineError.conflict }
    }
    static func validate(_ mutation: CalendarMutation) throws {
        switch mutation {
        case .create(let event), .importEvent(let event): try validateEvent(event)
        case .importSeries(let master, let exceptions):
            try validateEvent(master)
            guard exceptions.allSatisfy({ $0.originalStartTime?.resolvedDate() != nil }) else { throw CalendarEngineError.invalidEvent }
        case .update(let id, let fields, let etag):
            let forbidden: Set<String> = ["id", "etag", "organizer", "creator", "iCalUID", "recurringEventId", "originalStartTime"]
            guard !id.isEmpty, etag?.isEmpty == false, !fields.isEmpty, forbidden.isDisjoint(with: fields.keys) else { throw CalendarEngineError.invalidOperation }
        case .delete(let id, let etag): guard !id.isEmpty, etag?.isEmpty == false else { throw CalendarEngineError.invalidOperation }
        case .deleteFollowing(let id, let etag, let start):
            guard !id.isEmpty, etag?.isEmpty == false, start.resolvedDate() != nil else { throw CalendarEngineError.invalidOperation }
        case .respond(let id, let status, let etag):
            guard !id.isEmpty, etag?.isEmpty == false, ["accepted", "tentative", "declined"].contains(status) else { throw CalendarEngineError.invalidOperation }
        case .move(let id, let destination, let etag): guard !id.isEmpty, !destination.isEmpty, etag?.isEmpty == false else { throw CalendarEngineError.invalidOperation }
        case .splitSeries(let id, let etag, let start, let following, _):
            guard !id.isEmpty, etag?.isEmpty == false, start.resolvedDate() != nil else { throw CalendarEngineError.invalidOperation }
            try validateEvent(following)
        }
    }
    static func validateEvent(_ event: GoogleCalendarEvent) throws {
        guard let start = event.start, let end = event.end, start.isAllDay == end.isAllDay,
              let a = start.resolvedDate(), let b = end.resolvedDate(), b > a else { throw CalendarEngineError.invalidEvent }
    }
    private static func isDefiniteRejection(_ error: any Error) -> Bool {
        if let code = httpStatus(error), [400, 401, 403, 404, 409, 410, 412, 422].contains(code) { return true }
        if error is CalendarEngineError { return true }
        if case .invalidRequest = error as? GmailError { return true }
        return false
    }

    static func httpStatus(_ error: any Error) -> Int? {
        if case .http(let status, _) = error as? GmailError { return status }
        return nil
    }
    static func message(for error: any Error) -> String {
        if let error = error as? CalendarEngineError { return error.localizedDescription }
        if Self.httpStatus(error) == 412 { return CalendarEngineError.conflict.localizedDescription }
        if Self.isOffline(error) { return "Calendar changes are waiting for a connection. Retry when online." }
        if let error = error as? GmailError, error.isMissingScope || error == .unauthorized { return "Reconnect this Google account's calendar access." }
        return "Google could not save this calendar change. Review it and try again."
    }
}
