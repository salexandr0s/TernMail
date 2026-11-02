import Foundation
import GmailAPI
import MailStore
import SyncEngine

extension CalendarModel {
    func recoveryReview(for operation: CalendarOperation) async throws -> CalendarOperationRecovery {
        guard let engine = engines[operation.accountID] else { throw CalendarModelError.unavailable }
        let revision = lifecycleRevision
        let review = try await engine.reviewRecovery(operationID: operation.id)
        guard revision == lifecycleRevision else { throw CalendarModelError.unavailable }
        return review
    }

    func recover(_ review: CalendarOperationRecovery, discard: Bool = false) async throws {
        guard let engine = engines[review.operation.accountID] else { throw CalendarModelError.unavailable }
        if discard { try await engine.discardRecovery(review) }
        else {
            try await engine.resumeRecovery(review)
            try await engine.flush()
        }
        await reloadOperations(); await reloadOccurrences(); await refreshNotifications()
    }

    func recoveryDraft(for review: CalendarOperationRecovery) throws -> CalendarEditorDraft {
        guard review.canEdit,
              let owner = calendars.first(where: { $0.accountID == review.operation.accountID && $0.calendarID == review.operation.calendarID }) else {
            throw CalendarModelError.unavailable
        }
        var draft: CalendarEditorDraft
        switch review.reviewedMutation {
        case .create(let event): draft = CalendarEditorDraft(event: event, calendarKey: owner.id)
        case .importEvent(let event): draft = CalendarEditorDraft(event: event, calendarKey: owner.id, isImport: true)
        case .importSeries(let event, let exceptions):
            draft = CalendarEditorDraft(event: event, calendarKey: owner.id, isImport: true, importedExceptions: exceptions)
        case .update(let id, let fields, _):
            guard let current = review.currentEvents.first(where: { $0.id == id }) else { throw CalendarModelError.changed }
            var edited = current
            for (key, value) in fields { edited.rawValue[key] = value == .null ? nil : value }
            let source = CalendarDisplayEvent(event: current, accountID: owner.accountID, calendarID: owner.calendarID,
                canEdit: owner.canWrite, fallbackTimeZoneID: calendar.timeZone.identifier)
            draft = CalendarEditorDraft(event: edited, calendarKey: owner.id, source: source)
            if current.recurrence?.isEmpty == false { draft.seriesMaster = current; draft.editScope = .series }
        case .splitSeries(let id, _, let start, let following, _):
            guard let master = review.currentEvents.first(where: { $0.id == id }) else { throw CalendarModelError.changed }
            var occurrence = master
            occurrence.recurringEventId = master.id; occurrence.originalStartTime = start
            occurrence.start = start
            if let from = master.start?.resolvedDate(), let to = master.end?.resolvedDate(), let date = start.resolvedDate() {
                occurrence.end = CalendarDateTime(date: date.addingTimeInterval(to.timeIntervalSince(from)),
                    timeZone: TimeZone(identifier: start.timeZone ?? "") ?? calendar.timeZone, allDay: start.isAllDay)
            }
            let source = CalendarDisplayEvent(event: occurrence, accountID: owner.accountID, calendarID: owner.calendarID,
                canEdit: owner.canWrite, fallbackTimeZoneID: calendar.timeZone.identifier)
            draft = CalendarEditorDraft(event: following, calendarKey: owner.id, source: source)
            draft.seriesMaster = master; draft.editScope = .following
            draft.followingExceptionsCount = max(0, review.currentEvents.count - 1)
        default: throw CalendarModelError.unavailable
        }
        draft.additionalNotificationRecipients = review.currentEvents.flatMap { ($0.attendees ?? []).map(\.email) }
        draft.operationID = review.id; draft.recovery = review
        return draft
    }
}
