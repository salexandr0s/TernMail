import AppKit
import GmailAPI
import SwiftUI
import Testing
@testable import Tern

/// Production Calendar pages and sheets backed by the local CalendarAudit service.
@Suite(.serialized) @MainActor struct CalendarDesignVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_CALENDAR_DESIGN_AUDIT_DIR"] != nil))
    func renderCalendar() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"),
            "Calendar captures require the isolated UI audit environment")
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_CALENDAR_DESIGN_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let storedMode = CalendarDefaults.store.object(forKey: CalendarDisplayMode.storageKey)
        defer { CalendarDefaults.store.set(storedMode, forKey: CalendarDisplayMode.storageKey) }

        for scheme in [ColorScheme.light, .dark] {
            let fixture = try await CalendarDesignFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            let theme = scheme == .light ? "light" : "dark"
            CalendarDefaults.store.set(CalendarDisplayMode.week.rawValue, forKey: CalendarDisplayMode.storageKey)
            let host = CalendarDesignCaptureHost(content: CalendarView(model: model).environment(fixture.app)
                .defaultAppStorage(fixture.defaults), size: NSSize(width: 1_280, height: 800), scheme: scheme)
            defer { host.close() }
            try await host.waitUntil("Calendar header") {
                host.contains("Go to date,")
            }
            for mode in CalendarDisplayMode.allCases {
                try await fixture.show(mode)
                try await host.capture("\(mode.rawValue)-1280-\(theme)", directory: directory)
            }
            for mode in [CalendarDisplayMode.week, .month] {
                host.window.setContentSize(NSSize(width: 720, height: 480))
                try await fixture.show(mode)
                try await host.capture("\(mode.rawValue)-720-\(theme)", directory: directory)
            }

            host.window.setContentSize(NSSize(width: 1_280, height: 800))
            try await fixture.show(.week)
            let recurringEvent = model.events.first(where: \.isRecurring)
            let recurring = try #require(recurringEvent)
            let readOnly = try #require(model.events.first { !$0.canEdit })
            try await captureEditors(model: model, recurring: recurring, readOnly: readOnly,
                host: host, theme: theme, directory: directory)

            try await fixture.makeBusyDay()
            try await fixture.show(.day)
            try await host.capture("day-twelve-events-1280-\(theme)", directory: directory)
            let sidebar = CalendarDesignCaptureHost(content: CalendarSidebar(model: model, manage: {}, connect: { _ in })
                .environment(\.timeZone, model.calendar.timeZone),
                size: NSSize(width: 280, height: 800), scheme: scheme)
            defer { sidebar.close() }
            try await sidebar.capture("sidebar-twelve-events-280-\(theme)", directory: directory)
            try sidebar.scrollToBottom()
            try await sidebar.capture("sidebar-twelve-events-bottom-280-\(theme)", directory: directory)
            sidebar.close()

            for size in [NSSize(width: 1_280, height: 800), NSSize(width: 720, height: 480)] {
                host.window.setContentSize(size)
                try await fixture.show(.month)
                try await host.capture("month-twelve-events-\(Int(size.width))-\(theme)", directory: directory)
            }
            host.window.setContentSize(NSSize(width: 1_280, height: 800))

            let owners = model.calendars
            for owner in owners { model.setVisible(id: owner.id, visible: false) }
            await model.activateRange()
            try await host.waitUntil("Hidden calendars state") {
                !model.calendars.isEmpty && model.calendars.allSatisfy { !$0.isVisible }
                    && host.contains("No Calendars Selected") && host.contains("Show All Calendars")
            }
            try await host.capture("calendars-hidden-1280-\(theme)", directory: directory)
            model.calendars = []
            model.accounts = []
            try await host.waitUntil("Empty calendars state") { host.contains("Your calendars in Tern") }
            try await host.capture("calendars-empty-1280-\(theme)", directory: directory)
            host.close()
            await model.stop()
        }
    }

    private func captureEditors(model: CalendarModel, recurring: CalendarDisplayEvent, readOnly: CalendarDisplayEvent,
                                host: CalendarDesignCaptureHost, theme: String, directory: String) async throws {
        // SidebarLayoutTests exercises the window toolbar's New Event action.
        // This standalone host verifies the same model's presented editor.
        model.beginNew(on: model.date)
        try await host.waitUntil("New event sheet") { model.editor?.isNew == true && host.window.sheets.first != nil }
        try await captureSheet("editor-new-\(theme)", host: host, directory: directory)
        model.editor = nil
        try await host.waitUntil("New event sheet closes") { host.window.sheets.isEmpty }

        model.edit(recurring)
        try await host.waitUntil("Recurring event sheet") {
            model.editor?.seriesMaster != nil && model.editor?.followingExceptionsCount != nil && host.window.sheets.first != nil
        }
        try await captureSheet("editor-recurring-\(theme)", host: host, directory: directory)
        model.editor = nil
        try await host.waitUntil("Recurring event sheet closes") { host.window.sheets.isEmpty }

        model.edit(readOnly)
        try await host.waitUntil("Read-only event sheet") {
            model.editor?.source?.canEdit == false && host.window.sheets.first != nil
        }
        try await captureSheet("editor-read-only-\(theme)", host: host, directory: directory)
        model.editor = nil
        try await host.waitUntil("Read-only event sheet closes") { host.window.sheets.isEmpty }
    }

    private func captureSheet(_ name: String, host: CalendarDesignCaptureHost, directory: String) async throws {
        let sheet = try #require(host.window.sheets.first)
        try await host.capture(name, directory: directory, window: sheet)
        try host.scrollToBottom(window: sheet)
        try await host.capture(name + "-bottom", directory: directory, window: sheet)
    }
}

@MainActor private final class CalendarDesignFixture {
    let app = AppModel()
    let model: CalendarModel
    let defaults: UserDefaults
    private let suite = "CalendarDesignVisualAudit." + UUID().uuidString

    init() async throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: DomainLogoImages.preferenceKey)
        model = CalendarModel(app: nil, defaults: defaults)
        model.workingHours.timeZoneIdentifier = "Europe/Vienna"
        model.firstWeekday = 2
        model.date = model.calendar.startOfDay(for: .now)
        await model.seedCalendarAudit()
        try #require(model.errorMessage == nil, "The local calendar fixture must load before capture")
        try #require(model.calendars.count == 3)
        try #require(model.services.values.allSatisfy { $0 is CalendarAuditService })
    }

    func show(_ mode: CalendarDisplayMode) async throws {
        model.mode = mode
        await model.activateRange()
        await model.activateSidebarMonth()
        try #require(model.presentation?.interval == model.displayInterval,
            "The captured mode must have its own prepared event range")
        try #require(model.errorMessage == nil)
    }

    func makeBusyDay() async throws {
        let service = try #require(model.services["calendar-audit"] as? CalendarAuditService)
        let week = try #require(model.calendar.dateInterval(of: .weekOfYear, for: model.date))
        model.date = try #require(model.calendar.date(byAdding: .day, value: 6, to: week.start))
        let day = try #require(model.calendar.dateInterval(of: .day, for: model.date))
        let expectedIDs = Set((0..<12).map { "design-busy-\($0)" })
        for index in 0..<12 {
            let start = try #require(model.calendar.date(bySettingHour: 8 + index, minute: 0, second: 0, of: model.date))
            var event = GoogleCalendarEvent(id: "design-busy-\(index)",
                summary: index.isMultiple(of: 3) ? "Project review with the research and engineering teams" : "Planning session \(index + 1)",
                start: CalendarDateTime(date: start, timeZone: model.calendar.timeZone),
                end: CalendarDateTime(date: start.addingTimeInterval(index.isMultiple(of: 3) ? 5_400 : 1_800), timeZone: model.calendar.timeZone))
            event.location = index.isMultiple(of: 2) ? "Vienna office · Meeting room 4" : nil
            _ = try await service.insertEvent(calendarID: "work", event: event, sendUpdates: "none")
        }
        let stored = try await service.events(calendarID: "work",
            query: CalendarEventQuery(timeMin: day.start, timeMax: day.end, singleEvents: true, showDeleted: false))
        try #require(Set(stored.items.map(\.id)) == expectedIDs, "The local service must contain all twelve busy-day events")
        await model.refreshCalendarAudit()
        try #require(model.errorMessage == nil)
        let currentService = try #require(model.services["calendar-audit"] as? CalendarAuditService)
        try #require(currentService === service, "Refresh must retain the service that received the busy-day events")
        // Direct fixture inserts bypass normal model mutation invalidation. Clear
        // the previously prepared empty Sunday before asking for its new agenda.
        model.invalidateRangeSnapshots()
        let request = model.sidebarRequest
        let deadline = ContinuousClock.now + .seconds(8)
        repeat {
            await model.activateSidebarMonth()
            let ids = Set((model.sidebarPresentation?.agenda(on: model.date, calendar: model.calendar) ?? []).map(\.event.id))
            if model.sidebarSnapshotRequest == request && ids == expectedIDs { break }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline
        try #require(model.sidebarSnapshotRequest == request, "The busy-day agenda must use the refreshed sidebar request")
        let agenda = model.sidebarPresentation?.agenda(on: model.date, calendar: model.calendar) ?? []
        try #require(agenda.count == 12, "The busy-day capture must contain twelve events")
        try #require(Set(agenda.map(\.event.id)) == expectedIDs)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        Task { await model.stop() }
    }
}

@MainActor private final class CalendarDesignCaptureHost {
    let window: NSWindow
    private let controller: NSHostingController<AnyView>

    init<Content: View>(content: Content, size: NSSize, scheme: ColorScheme) {
        controller = NSHostingController(rootView: AnyView(content.environment(\.colorScheme, scheme)))
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window.close()
        window.contentViewController = nil
    }

    func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        repeat { try await settle() } while !condition() && ContinuousClock.now < deadline
        try #require(condition(), "\(description)")
    }

    func contains(_ label: String) -> Bool {
        guard let root = window.contentView else { return false }
        return WorkspaceAuditAccessibility.elements(in: root).contains { element in
            guard element.isVisible(in: window) else { return false }
            let value = element.object.responds(to: NSSelectorFromString("accessibilityValue"))
                ? element.object.value(forKey: "accessibilityValue") as? String
                : element.object.accessibilityAttributeValue(.value) as? String
            return [element.label, value].compactMap { $0 }.contains { $0.contains(label) }
        }
    }

    func capture(_ name: String, directory: String, window target: NSWindow? = nil) async throws {
        let target = target ?? window
        try await settle()
        target.layoutIfNeeded()
        let data = try await NativeWindowCapture.png(of: target)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }

    func scrollToBottom(window target: NSWindow? = nil) throws {
        let root = try #require((target ?? window).contentView)
        let scroll = try #require(Self.descendants(root).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
        })
        let document = try #require(scroll.documentView)
        let bottom = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func settle() async throws {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
