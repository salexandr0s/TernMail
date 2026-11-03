import AppKit
import GmailAPI
import MailStore
import ScreenCaptureKit
import SwiftUI
import Testing
import WebKit
@testable import Tern

/// Opt-in captures of the real workspace, with in-memory mail and calendar services.
@Suite(.serialized) @MainActor struct ReadmeScreenshots {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_README_SCREENSHOTS"] == "1"))
    func captureWorkspace() async throws {
        try #require(ReadmeDemoFixtures.isEnabled)
        let suite = "ReadmeScreenshots-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: DomainLogoPreferences.key)
        defaults.set("all", forKey: "mailColumnVisibility")
        defaults.set(false, forKey: MailWindowPreferences.hidesReaderKey)
        defaults.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        defaults.set(false, forKey: "sidebarFavoritesCollapsed")
        let previousCalendarMode = CalendarDefaults.store.object(forKey: CalendarDisplayMode.storageKey)
        CalendarDefaults.store.set(CalendarDisplayMode.week.rawValue, forKey: CalendarDisplayMode.storageKey)
        defer { CalendarDefaults.store.set(previousCalendarMode, forKey: CalendarDisplayMode.storageKey) }

        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        try await waitUntil { mailbox.accounts.count == 2 && mailbox.accounts.allSatisfy(\.hasSyncedOnce) }
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        try await waitUntil { mailbox.threads.count >= 14 }
        let selected = ThreadKey(accountID: "ui-audit", threadID: "demo-collection")
        mailbox.selectedThreadIDs = [selected]
        for owner in mailbox.accounts {
            for label in owner.labels where !label.isSystem {
                let icons = ["Projects": "briefcase", "Design": "lightbulb", "Finance": "creditcard",
                    "Read later": "book", "Travel": "airplane", "Friends": "person.2", "Receipts": "doc.text"]
                LabelAppearance.shared.setIcon(icons[label.name] ?? "tag", labelID: label.id, accountID: owner.account.id)
            }
        }
        await app.calendar.start()
        app.calendar.date = ReadmeDemoFixtures.date
        app.calendar.firstWeekday = 2
        app.calendar.workingHours.timeZoneIdentifier = "Europe/Vienna"
        await app.calendar.seedCalendarAudit()
        try await populateCalendar(app.calendar)
        app.destination = .mail

        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox)
            .environment(app).modifier(AddressAvatarEnvironment(app: app))
            .environment(\.workspaceToolbarID, "ReadmeWorkspace")
            .environment(\.locale, Locale(identifier: "en_US"))
            .defaultAppStorage(defaults))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.title = "Tern"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1500, height: 940))
        window.center()
        window.level = .floating
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.close() }

        for (name, appearance) in [("mail-light", NSAppearance.Name.aqua), ("mail-dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            mailbox.selectedThreadIDs = [selected]
            try await waitForMessage(in: controller.view)
            try await Task.sleep(for: .milliseconds(500))
            try await capture(window: window, name: name)
        }
        app.destination = .calendar
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .seconds(2))
        try await capture(window: window, name: "calendar")
        await app.calendar.stop()
        await mailbox.stop()
    }

    private func populateCalendar(_ model: CalendarModel) async throws {
        let service = try #require(model.services["calendar-audit"])
        let week = try #require(model.calendar.dateInterval(of: .weekOfYear, for: model.date)?.start)
        let schedule = [(0, 11, "Collection photography", "work"), (0, 14, "Website handoff", "work"),
            (1, 11, "Autumn collection review", "work"), (1, 14, "Brand workshop", "work"),
            (2, 14, "Print proofs", "work"), (3, 10, "Studio open morning", "work"),
            (3, 14, "Editorial planning", "work"), (4, 10, "Launch checklist", "work"),
            (5, 10, "Ceramics workshop", "personal"), (6, 16, "Sunday dinner", "personal")]
        for (index, item) in schedule.enumerated() {
            let day = try #require(model.calendar.date(byAdding: .day, value: item.0, to: week))
            let start = try #require(model.calendar.date(bySettingHour: item.1, minute: 0, second: 0, of: day))
            let event = GoogleCalendarEvent(id: "readme-\(index)", summary: item.2,
                start: .init(date: start, timeZone: model.calendar.timeZone),
                end: .init(date: start.addingTimeInterval(3600), timeZone: model.calendar.timeZone))
            _ = try await service.insertEvent(calendarID: item.3, event: event, sendUpdates: "none")
        }
        await model.refreshCalendarAudit()
        #expect(model.events.count >= 16)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition())
    }

    private func waitForMessage(in root: NSView) async throws {
        func webViews(_ view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            for web in webViews(root) where !web.isLoading && !web.isHiddenOrHasHiddenAncestor {
                let text = try? await web.evaluateJavaScript("document.body.textContent", in: nil,
                    contentWorld: .defaultClient) as? String
                if text?.contains("The warmer palette works beautifully") == true { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("The fictional message body did not finish rendering before capture.")
        throw CocoaError(.coderValueNotFound)
    }

    private func capture(window: NSWindow, name: String) async throws {
        let data = try await Self.windowPixels(id: CGWindowID(window.windowNumber),
            width: Int(window.frame.width * 2), height: Int(window.frame.height * 2))
        Attachment.record(Array(data), named: name + ".png")
    }

    nonisolated private static func windowPixels(id: CGWindowID, width: Int, height: Int) async throws -> Data {
        // Limit capture to this process and this exact synthetic window. Unlike
        // view caching, ScreenCaptureKit includes vibrancy and WebKit surfaces.
        let content = try await SCShareableContent.currentProcess
        let target = try #require(content.windows.first { $0.windowID == id })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let pixels = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try #require(NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]))
    }
}
