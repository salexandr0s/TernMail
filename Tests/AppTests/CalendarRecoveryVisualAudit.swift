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
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"),
            "Calendar recovery captures require the isolated UI audit environment")
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
                let bottom = scheme == .dark
                try await capture(CalendarRecoveryView(model: model, operation: operation),
                    name: operation.id + "-" + name + (bottom ? "-bottom" : ""),
                    size: NSSize(width: width, height: 620), scheme: scheme, directory: directory,
                    readyIdentifier: "calendar.recovery.resume", bottom: bottom)
            }
        }
        model.operations = RecoveryAuditCalendarService.activityOperations
        try await capture(CalendarActivityView(model: model), name: "activity-mixed-760-light",
            size: NSSize(width: 760, height: 800), scheme: .light, directory: directory)
        try await capture(CalendarImportReview(events: RecoveryAuditCalendarService.importItems,
            calendars: model.calendars) { _, _ in
                Issue.record("The visual audit must not submit an import")
            }, name: "import-review-620-dark", size: NSSize(width: 620, height: 620),
            scheme: .dark, directory: directory, readyIdentifier: "calendar.import.save")
        await engine.stop()
    }

    private func capture<Content: View>(_ content: Content, name: String, size: NSSize,
                                       scheme: ColorScheme, directory: String,
                                       readyIdentifier: String? = nil, bottom: Bool = false) async throws {
        let controller = NSHostingController(rootView: content.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentViewController = nil }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let deadline = ContinuousClock.now + .seconds(8)
        repeat {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        } while readyIdentifier.map({ WorkspaceAuditAccessibility.matching($0, in: window).isEmpty }) == true
            && ContinuousClock.now < deadline
        if let readyIdentifier {
            try #require(!WorkspaceAuditAccessibility.matching(readyIdentifier, in: window).isEmpty,
                "The requested Calendar view must finish loading before capture")
        }
        if bottom {
            let scroll = try #require(Self.descendants(controller.view).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
            })
            let document = try #require(scroll.documentView)
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await Task.sleep(for: .milliseconds(200))
        let data = try await NativeWindowCapture.png(of: window)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
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

    static var activityOperations: [CalendarOperation] {
        let date = original.startDate ?? .distantPast
        var saved = CalendarOperation(id: "saved-event", accountID: "audit", calendarID: "team",
            mutation: .create(original), status: .completed, createdAt: date)
        saved.resultEvent = original
        let queued = CalendarOperation(id: "queued-event", accountID: "audit", calendarID: "team",
            mutation: .create(original), status: .queued, createdAt: date)
        let proposal = CalendarOperation(id: "proposed-event", accountID: "audit", calendarID: "team",
            mutation: .create(original), status: .proposed, createdAt: date)
        return [saved, queued, proposal] + operations.prefix(1)
    }

    static var importItems: [CalendarImportItem] {
        var series = original
        series.id = "import-series"; series.summary = "Weekly design review"
        series.recurrence = ["RRULE:FREQ=WEEKLY;COUNT=5"]
        var exception = original
        exception.id = "import-exception"; exception.recurringEventId = series.id
        exception.originalStartTime = series.start
        exception.summary = "Design review with the research team"
        var cancelled = original
        cancelled.id = "cancelled-import"; cancelled.summary = "Cancelled planning session"; cancelled.status = "cancelled"
        return [.init(event: original), .init(event: series, exceptions: [exception]), .init(event: cancelled)]
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
