import AppKit
import GmailAPI
import MailStore
import SwiftUI
import SyncEngine
import Testing
@testable import Tern

/// Captures the production recovery sheet with an in-memory queue and a local
/// calendar service. No account, network, notification or user preference writes.
@Suite(.serialized) @MainActor struct CalendarRecoveryVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_CALENDAR_RECOVERY_AUDIT_DIR"] != nil))
    func renderRecovery() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_CALENDAR_RECOVERY_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "CalendarRecoveryVisualAudit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try CalendarStore.inMemory()
        let service = RecoveryAuditCalendarService()
        let engine = CalendarSyncEngine(accountID: "audit", service: service, store: store)
        _ = try await engine.syncCalendars()
        let model = CalendarModel(app: nil, defaults: defaults)
        model.store = store; model.engines["audit"] = engine
        model.workingHours.timeZoneIdentifier = "Europe/Vienna"
        model.calendars = [CalendarDisplayCalendar(entry: RecoveryAuditCalendarService.entry,
            accountID: "audit", accountName: "Alex Morgan")]
        let operations = RecoveryAuditCalendarService.operations
        for operation in operations { try await store.saveOperation(operation) }
        model.operations = operations
        for operation in operations {
            let review = try await model.recoveryReview(for: operation)
            #expect(!review.currentEvents.isEmpty)
            if case .splitSeries = operation.mutation {
                #expect(review.completedStep == 1)
                #expect(!review.canEdit && !review.canDiscard)
            }
            for (name, width, scheme) in [("wide-light", 760.0, ColorScheme.light), ("narrow-dark", 620.0, .dark)] {
                let controller = NSHostingController(rootView: CalendarRecoveryView(model: model, operation: operation)
                    .frame(width: width, height: 620).environment(\.colorScheme, scheme))
                controller.sizingOptions = []
                let window = NSWindow(contentViewController: controller)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: width, height: 620))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                try await Task.sleep(for: .milliseconds(350))
                controller.view.layoutSubtreeIfNeeded()
                let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let filename = operation.id + "-" + name + ".png"
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
                Attachment.record(Array(data), named: filename)
                window.close()
            }
        }
        await engine.stop()
    }

    @Test func aReviewedUpdateDraftCombinesLocalFieldsWithTheCurrentRemoteEvent() async throws {
        let suite = "CalendarRecoveryModelTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try CalendarStore.inMemory()
        let service = RecoveryAuditCalendarService()
        let engine = CalendarSyncEngine(accountID: "audit", service: service, store: store)
        _ = try await engine.syncCalendars()
        let model = CalendarModel(app: nil, defaults: defaults)
        model.store = store; model.engines["audit"] = engine
        model.calendars = [.init(entry: RecoveryAuditCalendarService.entry, accountID: "audit", accountName: "Audit")]
        let operation = try #require(RecoveryAuditCalendarService.operations.first { $0.id == "failed-update" })
        try await store.saveOperation(operation)
        let review = try await model.recoveryReview(for: operation)
        let draft = try model.recoveryDraft(for: review)
        #expect(draft.event.summary == "Design review moved by the team")
        #expect(draft.event.description == "My notes for the review")
        #expect(draft.source?.event.etag == "current")
        #expect(draft.recovery == review)
        model.reviewOperation(operation)
        #expect(model.recoveryOperation?.id == operation.id)
        #expect(model.editor == nil)
        await engine.stop()
    }

    @Test func partialSeriesActivityNamesTheRequestedOccurrence() throws {
        let operation = try #require(RecoveryAuditCalendarService.operations.first { $0.id == "partial-series" })
        let presentation = CalendarOperationPresentation(operation: operation)
        #expect(presentation.title == "Change following events: Weekly design review")
        #expect(presentation.event?.start?.dateTime == "2026-11-09T14:00:00+01:00")
    }
}

private actor RecoveryAuditCalendarService: CalendarService {
    static let entry = GoogleCalendarEntry(id: "team", summary: "Product & engineering", timeZone: "Europe/Vienna", accessRole: "owner")

    static var original: GoogleCalendarEvent {
        var event = GoogleCalendarEvent(id: "review", summary: "Design review",
            start: .init(dateTime: "2026-11-09T10:00:00+01:00", timeZone: "Europe/Vienna"),
            end: .init(dateTime: "2026-11-09T11:00:00+01:00", timeZone: "Europe/Vienna"))
        event.etag = "old"; event.location = "Vienna office · Room 4"
        event.description = "Review the dashboard changes and open questions."
        event.attendees = [.init(email: "alex@example.invalid", displayName: "Alex", responseStatus: "accepted"),
            .init(email: "sam@example.invalid", displayName: "Sam", responseStatus: "needsAction")]
        event.hangoutLink = "https://meet.google.com/example-audit"
        event.htmlLink = "https://calendar.google.com/"
        return event
    }

    static var operations: [CalendarOperation] {
        let original = original
        var update = CalendarOperation(id: "failed-update", accountID: "audit", calendarID: "team",
            mutation: .update(eventID: original.id, fields: ["description": .string("My notes for the review")], etag: "old"), status: .conflicted)
        update.beforeEvent = original; update.attempts = 1
        var master = original; master.id = "series"; master.summary = "Weekly design review"
        master.recurrence = ["RRULE:FREQ=WEEKLY;COUNT=5"]
        master.start = .init(dateTime: "2026-11-02T10:00:00+01:00", timeZone: "Europe/Vienna")
        master.end = .init(dateTime: "2026-11-02T11:00:00+01:00", timeZone: "Europe/Vienna")
        var following = master; following.id = "partialseriesa"
        following.start = .init(dateTime: "2026-11-09T14:00:00+01:00", timeZone: "Europe/Vienna")
        following.end = .init(dateTime: "2026-11-09T15:00:00+01:00", timeZone: "Europe/Vienna")
        following.recurrence = ["RRULE:FREQ=WEEKLY;COUNT=4"]
        var split = CalendarOperation(id: "partial-series", accountID: "audit", calendarID: "team",
            mutation: .splitSeries(eventID: master.id, etag: master.etag,
                originalStart: .init(dateTime: "2026-11-09T10:00:00+01:00", timeZone: "Europe/Vienna"),
                followingEvent: following, resetExceptionsConfirmed: true), status: .conflicted)
        split.beforeEvent = master; split.resultEvent = master; split.attempts = 1; split.completedStep = 1
        split.preparedRecurrence = ["RRULE:FREQ=WEEKLY;UNTIL=20261109T085959Z"]
        split.preparedMutation = .create(following); split.affectedEventVersions = ["exception": "old"]
        return [update, split]
    }

    func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage { .init(items: [Self.entry]) }
    func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
        var event = Self.original
        switch eventID {
        case "review": event.summary = "Design review moved by the team"; event.etag = "current"
        case "series":
            event.id = eventID; event.summary = "Weekly design review"; event.etag = "trimmed"
            event.recurrence = ["RRULE:FREQ=WEEKLY;UNTIL=20261109T085959Z"]
            event.extendedProperties = .init(privateProperties: ["ternOperation": "partial-series-trim"])
        case "exception":
            event.id = eventID; event.summary = "Design review with the research team"; event.etag = "changed"
            event.recurringEventId = "series"
            event.originalStartTime = .init(dateTime: "2026-11-16T10:00:00+01:00")
            event.start = .init(dateTime: "2026-11-16T10:00:00+01:00", timeZone: "Europe/Vienna")
            event.end = .init(dateTime: "2026-11-16T11:00:00+01:00", timeZone: "Europe/Vienna")
        default: throw GmailError.notFound
        }
        return event
    }
}
