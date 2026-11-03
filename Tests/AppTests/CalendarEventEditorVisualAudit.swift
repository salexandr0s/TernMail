import AppKit
import GmailAPI
import SwiftUI
import Testing
@testable import Tern

/// Opt-in captures use synthetic events and cached illustration avatars only.
@Suite(.serialized) @MainActor struct CalendarEventEditorVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_EVENT_EDITOR_AUDIT_DIR"] != nil))
    func renderAndExerciseEditor() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9, minute: 30)))
        let owner = CalendarDisplayCalendar(entry: .init(id: "personal", summary: "Personal", accessRole: "owner", backgroundColor: "#33b679"),
                                            accountID: "event-design-audit", accountName: "Alex Morgan")
        let team = CalendarDisplayCalendar(entry: .init(id: "team", summary: "Design & product", accessRole: "writer", backgroundColor: "#7986cb"),
                                           accountID: "event-team-audit", accountName: "Sam Chen")
        AccountProfileImages.shared.setAuditImage(SenderAccountLabel.auditImage, for: owner.accountID)
        AccountProfileImages.shared.setAuditImage(SenderAccountLabel.auditImage, for: team.accountID)
        let context = AddressAvatarContext(profileAccountIDs: ["alex@example.invalid": owner.accountID, "sam@example.invalid": team.accountID], identity: "event-editor-audit")
        var allDay = GoogleCalendarEvent(id: "stay", summary: "Stay at The Hoxton, Shepherd's Bush",
            start: .init(date: "2026-11-05"), end: .init(date: "2026-11-08"))
        allDay.location = "The Hoxton, London"
        var timed = GoogleCalendarEvent(id: "review", summary: "Design review",
            start: .init(date: start, timeZone: calendar.timeZone), end: .init(date: start.addingTimeInterval(3600), timeZone: calendar.timeZone))
        timed.attendees = [CalendarAttendee(email: "sam@example.invalid", displayName: "Sam Chen", responseStatus: "accepted"),
                           CalendarAttendee(email: "alex@example.invalid", displayName: "Alex Morgan", responseStatus: "needsAction")]
        timed.location = "Studio, second floor"
        var detailed = timed
        detailed.summary = "Planning the next release with the design and engineering teams"
        detailed.description = "Review the prototype and agree on the next milestones.\nBring feedback from the customer interviews."
        detailed.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=TH;UNTIL=20261231T225959Z"]
        detailed.reminders = CalendarEventReminders(useDefault: false, overrides: [CalendarReminder(minutes: 10)])
        for (name, event, scheme, height, readOnly) in [
            ("all-day-dark", allDay, ColorScheme.dark, 680.0, false),
            ("guests-light", timed, .light, 680.0, false),
            ("compact-dark", timed, .dark, 480.0, false),
            ("read-only-light", timed, .light, 680.0, true),
            ("details-dark", detailed, .dark, 680.0, false)
        ] {
            var draft = CalendarEditorDraft(event: event, calendarKey: owner.id)
            if readOnly {
                draft.source = CalendarDisplayEvent(event: event, accountID: owner.accountID, calendarID: owner.calendarID,
                    colorHex: owner.colorHex, canEdit: false)
            }
            try await render(CalendarEventEditor(draft: draft, calendars: [owner, team], calendar: calendar) { _ in
                Issue.record("Visual audit must never save an event")
            }.environment(\.addressAvatarContext, context), name: name, size: NSSize(width: 600, height: height), scheme: scheme, bottom: true)
        }

        var selected = start
        var closed = false
        let binding = Binding(get: { selected }, set: { selected = $0 })
        try await render(CalendarEventDatePopover(selection: binding, allDay: false, calendar: calendar, close: { closed = true }),
                         name: "date-popover-dark", size: NSSize(width: 320, height: 380), scheme: .dark) { view in
            try press("Next month", in: view)
            try await Task.sleep(for: .milliseconds(100))
            #expect(selected == start)
            #expect(!closed)
            let next = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 8)))
            let label = CalendarLayout.format(next, style: .dateTime.weekday(.wide).month(.wide).day().year(), calendar: calendar)
            try press(label, in: view)
            #expect(closed)
            #expect(calendar.component(.month, from: selected) == 12)
            #expect(calendar.component(.day, from: selected) == 8)
            #expect(calendar.component(.hour, from: selected) == 9)
            #expect(calendar.component(.minute, from: selected) == 30)
        }
        try await render(CalendarEventDatePopover(selection: .constant(start), allDay: true, calendar: calendar, close: {}),
                         name: "date-popover-light", size: NSSize(width: 320, height: 380), scheme: .light)
    }

    private func render<V: View>(_ content: V, name: String, size: NSSize, scheme: ColorScheme,
                                 bottom: Bool = false, inspect: ((NSView) async throws -> Void)? = nil) async throws {
        let controller = NSHostingController(rootView: content.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        window.makeFirstResponder(nil)
        try capture(controller.view, name: name)
        try await inspect?(controller.view)
        if bottom, let scroll = scrollView(in: controller.view), let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            try capture(controller.view, name: name + "-bottom")
        }
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_EVENT_EDITOR_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func press(_ label: String, in root: NSView) throws {
        var seen = Set<ObjectIdentifier>()
        var labels: [String] = []
        func find(_ item: Any) -> NSObject? {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func value(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
            if let text = value("accessibilityLabel") as? String { labels.append(text) }
            if [value("accessibilityLabel"), value("accessibilityValue")].contains(where: { ($0 as? String)?.contains(label) == true }),
               object.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return object }
            let children = value("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let found = find(child) { return found }
            }
            return nil
        }
        let found = find(root)
        let control = try #require(found, "Missing \(label); found: \(labels.prefix(50).joined(separator: ", "))")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try #require(control.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        // AppKit's public -(BOOL)accessibilityPerformPress method has this ABI.
        #expect(unsafeBitCast(implementation, to: Press.self)(control, selector))
    }
}
