import AppKit
import GmailAPI
import SwiftUI
import Testing
@testable import Tern

/// Opt-in native captures, using local events without a calendar connection.
@Suite(.serialized) @MainActor struct CalendarSidebarVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_CALENDAR_SIDEBAR_AUDIT_DIR"] != nil))
    func renderSidebar() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_CALENDAR_SIDEBAR_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "CalendarSidebarVisualAudit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(app: nil, defaults: defaults)
        model.workingHours.timeZoneIdentifier = "Europe/Vienna"
        model.firstWeekday = 2
        model.accounts = [.init(id: "work", title: "Alex Morgan")]
        let owners = [
            CalendarDisplayCalendar(entry: .init(id: "personal", summary: "Personal", accessRole: "owner", backgroundColor: "#33b679"), accountID: "work", accountName: "Alex Morgan"),
            CalendarDisplayCalendar(entry: .init(id: "team", summary: "Product & engineering team", accessRole: "reader", backgroundColor: "#7986cb"), accountID: "work", accountName: "Alex Morgan")
        ]
        let days = [3, 5, 5, 6, 9, 12, 18, 20, 25]
        let events = try days.enumerated().map { index, day -> CalendarDisplayEvent in
            let start = try #require(model.calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 9 + index % 3)))
            let owner = owners[index % 2]
            var event = GoogleCalendarEvent(id: "event-\(index)", summary: index == 1 ? "Product review and planning for the next release" : "Design review",
                start: .init(date: start), end: .init(date: start.addingTimeInterval(3600)))
            event.location = index == 1 ? "Vienna office" : nil
            return CalendarDisplayEvent(event: event, accountID: owner.accountID, calendarID: owner.calendarID, colorHex: owner.colorHex)
        }
        for (name, width, scheme, day, hidden) in [
            ("empty-220-dark", 220.0, ColorScheme.dark, 2, false),
            ("busy-248-dark", 248.0, .dark, 5, false),
            ("busy-320-light", 320.0, .light, 5, false),
            ("hidden-220-light", 220.0, .light, 2, true)
        ] {
            model.calendars = owners.map { var owner = $0; owner.isVisible = !hidden; return owner }
            model.date = try #require(model.calendar.date(from: DateComponents(year: 2026, month: 11, day: day)))
            let request = model.sidebarRequest
            model.sidebarSnapshotRequest = request
            model.sidebarSnapshot = CalendarRangeSnapshot(presentation: CalendarPresentationSnapshot(events: hidden ? [] : events,
                interval: request.range.interval, calendar: model.calendar, buildsTimeAxis: false), checkedAt: .now, stale: false, byteCost: 0)
            model.lastCheckedAt = .now
            let controller = NSHostingController(rootView: CalendarSidebar(model: model, manage: {}, connect: { _ in }, delete: { _ in })
                .frame(width: width, height: 850).environment(\.colorScheme, scheme))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 850))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            Attachment.record(Array(data), named: name + ".png")
            if day == 2, !hidden {
                let table = try #require(self.table(in: controller.view))
                for row in 0..<table.numberOfRows {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    try await Task.sleep(for: .milliseconds(50))
                    if model.selectedEventID != nil { break }
                }
                let selectedID = try #require(model.selectedEventID)
                let selected = try #require(events.first { $0.id == selectedID })
                #expect(model.calendar.isDate(model.date, inSameDayAs: selected.start))
                try await Task.sleep(for: .milliseconds(100))
                #expect(model.selectedEventID == selectedID)
                model.selectedEventID = nil
            }
            window.close()
        }
    }

    private func table(in view: NSView) -> NSTableView? {
        (view as? NSTableView) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
    }
}
