import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct FollowUpsViewTests {
    @Test func deadlineDaysAndMorningPresetsRespectCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 18)))
        let tomorrow = FollowUpSchedule.tomorrow(from: now, calendar: calendar)
        #expect(calendar.component(.day, from: tomorrow) == 25)
        #expect(calendar.component(.hour, from: tomorrow) == 9)
        let deadline = FollowUpSchedule.canonicalDeadline(now, calendar: calendar)
        #expect(!FollowUpSchedule.isOverdue(deadline, now: now, calendar: calendar))
        #expect(FollowUpSchedule.isOverdue(deadline, now: tomorrow, calendar: calendar))

        let fridayAfternoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15)))
        let friday = FollowUpSchedule.friday(from: fridayAfternoon, calendar: calendar)
        #expect(friday > fridayAfternoon)
        #expect(calendar.component(.weekday, from: friday) == 6)
        #expect(calendar.component(.day, from: friday) == 13)
        #expect(calendar.component(.hour, from: friday) == 9)
    }

    @Test func deadlineKeepsItsDayWhenTravellingWestAcrossTimeZones() throws {
        var vienna = Calendar(identifier: .gregorian)
        vienna.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let selection = try #require(vienna.date(from: DateComponents(year: 2026, month: 11, day: 9)))
        let deadline = FollowUpSchedule.canonicalDeadline(selection, calendar: vienna)
        let travelledSelection = FollowUpSchedule.pickerDate(from: deadline, calendar: newYork)
        #expect(newYork.dateComponents([.year, .month, .day], from: travelledSelection)
            == DateComponents(year: 2026, month: 11, day: 9))
        #expect(FollowUpSchedule.canonicalDeadline(travelledSelection, calendar: newYork) == deadline)
        #expect(FollowUpSchedule.deadlineText(deadline, locale: Locale(identifier: "en_US")) == "Nov 9, 2026")
        let evening = try #require(newYork.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 23)))
        #expect(FollowUpSchedule.isDueToday(deadline, now: evening, calendar: newYork))
        #expect(!FollowUpSchedule.isOverdue(deadline, now: evening, calendar: newYork))
        let nextDay = try #require(newYork.date(byAdding: .hour, value: 2, to: evening))
        #expect(FollowUpSchedule.isOverdue(deadline, now: nextDay, calendar: newYork))
    }

    @Test(.timeLimit(.minutes(1))) func nativeListEditsCapturedFollowUpAndCompletesIt() async throws {
        let store = try AccountStore.inMemory()
        let account = AccountRecord(id: "follow-up-layout", email: "alex@example.invalid", displayName: "Demo account",
            grantedScopes: [], addedAt: .distantPast)
        try await store.save(account)
        let now = Date.now
        let record = CommitmentRecord(accountID: account.id, id: "approval", threadID: "launch", sourceMessageID: "request",
            sourceMessageDate: now.addingTimeInterval(-3_600), sourceSubject: "Website launch review",
            title: "Confirm the revised launch date and approve the final copy", ownerName: "Sam", ownerEmail: "sam@example.invalid",
            direction: .waitingFor, dueAt: FollowUpSchedule.canonicalDeadline(now))
        let reminder = CommitmentReminderRecord(accountID: account.id, commitmentID: record.id, kind: .unresolved,
            remindAt: FollowUpSchedule.friday(from: now), baselineMessageID: record.sourceMessageID, baselineDate: record.sourceMessageDate)
        _ = try await store.createCommitment(record, reminders: [reminder])
        _ = try await store.createCommitment(CommitmentRecord(accountID: account.id, id: "proposal", threadID: "proposal",
            sourceMessageID: "proposal-request", sourceMessageDate: now, sourceSubject: "Updated project estimate",
            title: "Send the revised proposal", ownerName: "Jordan", direction: .owedByMe,
            dueAt: FollowUpSchedule.canonicalDeadline(FollowUpSchedule.tomorrow(from: now))))
        let model = FollowUpsModel(store: { store }, visibleAccountIDs: { [account.id] }, canReadAccount: { _ in false },
            loadThread: { _, _ in throw FollowUpModelError.unavailable },
            prepareDraft: { _ in throw FollowUpModelError.unavailable }, scheduler: SilentFollowUpNotificationScheduler(), now: { now })
        await model.refresh()
        defer { model.stop() }
        let controller = NSHostingController(rootView: FollowUpsView(model: model, isActive: false).followUpEditor(model: model))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 480))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.close(); window.contentViewController = nil }
        try await until { element("follow-up-edit-approval", in: controller.view) != nil }

        // The list takes the keyboard as the page comes to front and gives it up as the page goes behind.
        func listHasKeyboard() -> Bool { window.firstResponder is NSTableView }
        try #require(window.makeFirstResponder(nil))
        controller.rootView = FollowUpsView(model: model).followUpEditor(model: model)
        try await until { listHasKeyboard() }
        controller.rootView = FollowUpsView(model: model, isActive: false).followUpEditor(model: model)
        try await until { !listHasKeyboard() }
        // Under the utility panel in a narrow window, the page comes to front
        // hidden, and the list takes the keyboard once the page shows.
        controller.rootView = FollowUpsView(model: model, isActive: false, isInFront: true).followUpEditor(model: model)
        try await settle(window)
        #expect(!listHasKeyboard())
        controller.rootView = FollowUpsView(model: model).followUpEditor(model: model)
        try await until { listHasKeyboard() }
        try await settle(window)
        try capture(controller.view, name: "waiting-for-light")
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle(window)
        try capture(controller.view, name: "waiting-for-dark")

        let directionPicker = try #require(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 })
        directionPicker.selectedSegment = 1
        directionPicker.sendAction(directionPicker.action, to: directionPicker.target)
        model.selectedEntryID = try #require(model.entries.first { $0.record.id == record.id }).id
        try await settle(window)
        #expect(directionPicker.selectedSegment == 1, "Selecting an item must preserve the direction filter.")

        try #require(press(try #require(element("follow-up-edit-approval", in: controller.view))))
        try #require(model.pendingEditor != nil, "The row's Edit button must open the captured editor request.")
        try await until { window.attachedSheet?.contentView != nil }
        let sheet = try #require(window.attachedSheet)
        try await settle(sheet)
        try await until { sheet.contentView.map { element("follow-up-editor-save", in: $0) != nil } ?? false }
        let editorView = try #require(sheet.contentView)
        try capture(editorView, name: "follow-up-editor-dark")
        let title = try #require(descendants(editorView).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "What needs to happen?" })
        try #require(sheet.makeFirstResponder(title))
        let textEditor = try #require(title.currentEditor() as? NSTextView)
        textEditor.insertText("Approve the launch copy", replacementRange: NSRange(location: 0, length: textEditor.string.utf16.count))
        try #require(press(try #require(element("follow-up-editor-save", in: editorView))))
        try await until { model.pendingEditor == nil }
        let saved = try #require(try await store.commitmentEntries(accountIDs: [account.id]).first { $0.record.id == record.id })
        #expect(saved.record.title == "Approve the launch copy")
        #expect(saved.record.sourceMessageID == record.sourceMessageID)
        #expect(saved.reminders.first?.remindAt == reminder.remindAt)

        try await until {
            guard window.attachedSheet == nil,
                  let complete = element("follow-up-status-approval", in: controller.view) else { return false }
            return attribute("accessibilityEnabled", of: complete) as? Bool == true
        }
        try await settle(window)
        try #require(press(try #require(element("follow-up-status-approval", in: controller.view))))
        try await until {
            model.entries.first { $0.record.id == record.id }?.record.status == .completed
                && element("follow-up-edit-approval", in: controller.view) == nil
        }
    }

    private func settle(_ window: NSWindow) async throws {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func accessibilityObjects(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let children = attribute("accessibilityChildren", of: object) as? [NSObject] ?? []
            let unignored = NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject }
            for child in children + unignored + ((object as? NSView)?.subviews ?? []) { visit(child) }
        }
        visit(root)
        return result
    }

    private func attribute(_ name: String, of object: NSObject) -> Any? {
        let getter = name == "accessibilityEnabled" ? "isAccessibilityEnabled" : name
        if object.responds(to: NSSelectorFromString(getter)), let value = object.value(forKey: name) { return value }
        let legacy: NSAccessibility.Attribute?
        switch name {
        case "accessibilityChildren": legacy = .children
        case "accessibilityIdentifier": legacy = .identifier
        case "accessibilityRole": legacy = .role
        case "accessibilityEnabled": legacy = .enabled
        default: legacy = nil
        }
        guard let legacy, object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return object.accessibilityAttributeValue(legacy)
    }

    private func element(_ id: String, in root: NSView) -> NSObject? {
        let matches = accessibilityObjects(root).filter { attribute("accessibilityIdentifier", of: $0) as? String == id }
        return matches.first { attribute("accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue }
            ?? matches.first
    }

    private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        for candidate in accessibilityObjects(object) {
            if candidate.responds(to: selector), let implementation = candidate.method(for: selector) {
                // AppKit's public BOOL accessibilityPerformPress selector.
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(implementation, to: Press.self)(candidate, selector) { return true }
            }
            if candidate.responds(to: NSSelectorFromString("accessibilityActionNames")),
               candidate.accessibilityActionNames().contains(.press),
               candidate.responds(to: NSSelectorFromString("accessibilityPerformAction:")) {
                candidate.accessibilityPerformAction(.press)
                return true
            }
        }
        return false
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
    }
}
