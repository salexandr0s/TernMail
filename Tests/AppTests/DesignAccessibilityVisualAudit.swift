import AppKit
import GmailAPI
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Native captures with synthetic content and no account connection.
@Suite(.serialized) @MainActor struct DesignAccessibilityVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_DESIGN_ACCESSIBILITY_AUDIT_DIR"] != nil))
    func renderMailListAtTwoHundredPercent() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "The list audit requires synthetic accounts")
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while mailbox.listItems.isEmpty {
            try #require(ContinuousClock.now < deadline, "Synthetic mail did not load")
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try #require(mailbox.listItems.first?.messages.first)
        var message = original.message
        message.sender = "Alexandra Morgan with a longer name <alexandra@example.invalid>"
        message.subject = "Project planning and design review for the next release"
        message.snippet = "Please review the updated agenda before the next planning meeting."
        let labels = ["Accounts & Security", "Waiting for reply", "Design"].enumerated().map {
            LabelRecord(accountID: message.accountID, id: "audit-\($0.offset)", name: $0.element, isSystem: false)
        }
        let entry = MessageListEntry(message: message, labels: Set(labels.map(\.id)).union([SystemLabel.inbox, SystemLabel.unread]))
        let item = MessageListItem(id: .init(accountID: message.accountID, threadID: message.threadID), thread: entry.rowThread,
            messages: [entry], availableLabels: labels)
        let suite = "DesignAccessibilityVisualAudit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: DomainLogoImages.preferenceKey)
        for scale in [1.0, 2.0] {
            defaults.set(scale, forKey: ReadingPreferences.textScaleKey)
            for width in [340.0, 580.0] {
                try await capture(MessageListRow(item: item, mailbox: mailbox, accountMark: "Work", accountColor: .blue)
                    .padding(Tokens.Space.s2).environment(app).defaultAppStorage(defaults),
                    size: NSSize(width: width, height: 260), scheme: .light, contrast: .standard,
                    name: "mail-list-\(Int(scale * 100))-\(Int(width))")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_DESIGN_ACCESSIBILITY_AUDIT_DIR"] != nil))
    func renderCalendarIdentityAndSwatchSelection() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9)))
        let work = CalendarDisplayCalendar(entry: .init(id: "work", summary: "Work", backgroundColor: "#33b679"), accountID: "audit", accountName: "Alex Morgan")
        let personal = CalendarDisplayCalendar(entry: .init(id: "personal", summary: "Personal", backgroundColor: "#33b679"), accountID: "audit", accountName: "Alex Morgan")
        let event = CalendarDisplayEvent(event: .init(id: "review", summary: "Project planning and design review",
            start: .init(date: start), end: .init(date: start.addingTimeInterval(3_600))),
            accountID: work.accountID, calendarID: work.calendarID, colorHex: work.colorHex)
        let allDay = CalendarDisplayEvent(event: .init(id: "away", summary: "Out of office",
            start: .init(date: "2026-11-03"), end: .init(date: "2026-11-04")),
            accountID: personal.accountID, calendarID: personal.calendarID, colorHex: personal.colorHex)
        for (name, scheme, contrast) in [
            ("light", ColorScheme.light, ColorSchemeContrast.standard),
            ("dark", .dark, .standard),
            ("light-increased", .light, .increased),
            ("dark-increased", .dark, .increased)
        ] {
            try await capture(VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Differentiate Without Color").font(.headline)
                ForEach([24.0, 48, 64, 96], id: \.self) { height in
                    HStack {
                        Text("\(Int(height)) pt").frame(width: 48, alignment: .leading)
                        CalendarTimelineEvent(event: event, selected: height == 64, height: height, calendar: calendar)
                    }
                }
                Text("Month and all-day chips").font(.headline)
                CalendarEventChip(event: event)
                CalendarEventChip(event: allDay, selected: true, showsTime: false)
                CalendarEventChip(event: event).frame(width: 150)
            }
            .padding(Tokens.Space.s4)
            .environment(\.timeZone, calendar.timeZone)
            .environment(\.calendarIdentities, CalendarIdentityPresentation(calendars: [work, personal]))
            // The SDK exposes the writable audit override under an underscored key.
            .environment(\._accessibilityDifferentiateWithoutColor, true),
            size: NSSize(width: 380, height: 480), scheme: scheme, contrast: contrast, name: "calendar-identity-\(name)")
            try await capture(VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Selected swatches at 20 pt").font(.headline)
                ForEach(AccountAppearance.palette.indices, id: \.self) { index in
                    HStack {
                        Text(AccountAppearance.palette[index].name).frame(width: 60, alignment: .leading)
                        SwatchPicker(selection: .constant(index))
                    }
                }
            }.padding(Tokens.Space.s4), size: NSSize(width: 360, height: 320), scheme: scheme, contrast: contrast,
            name: "swatch-selection-\(name)")
        }
        let longOwner = CalendarDisplayCalendar(entry: .init(id: work.calendarID,
            summary: "Product engineering and release planning", backgroundColor: work.colorHex),
            accountID: work.accountID, accountName: work.accountName)
        try await capture(VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text("Schedule").font(.headline).padding(.horizontal, Tokens.Space.s4)
            CalendarScheduleView(date: start, calendar: calendar, events: [event, allDay], selectedID: .constant(nil),
                create: { _ in }, edit: { _ in }, delete: { _ in }, duplicate: { _ in })
                .frame(height: 280)
            Text("Search results").font(.headline).padding(.horizontal, Tokens.Space.s4)
            CalendarSearchResults(events: [event, allDay], calendar: calendar, selectedID: .constant(nil),
                edit: { _ in }, delete: { _ in }, duplicate: { _ in })
                .frame(height: 240)
        }
        .environment(\.calendarIdentities, CalendarIdentityPresentation(calendars: [longOwner, personal]))
        .environment(\._accessibilityDifferentiateWithoutColor, true),
        size: NSSize(width: 420, height: 600), scheme: .light, contrast: .standard, name: "calendar-list-identity-narrow")
    }

    private func capture(_ content: some View, size: NSSize, scheme: ColorScheme, contrast: ColorSchemeContrast,
                         name: String) async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_DESIGN_ACCESSIBILITY_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let controller = NSHostingController(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Tokens.Surface.primary).environment(\.colorScheme, scheme).environment(\._colorSchemeContrast, contrast))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        let appearance: NSAppearance.Name = contrast == .increased
            ? (scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (scheme == .dark ? .darkAqua : .aqua)
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }
}
