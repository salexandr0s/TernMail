import AppKit
import GmailAPI
@testable import MailStore
import MessageContent
import SwiftUI
import Testing
import TernAI
@testable import Tern

@Suite(.serialized) @MainActor struct MeetingPreparationViewTests {
    @Test(.timeLimit(.minutes(1))) func nativePreparationPreservesOccurrenceAndReviewsSources() async throws {
        let fixture = try await MeetingPreparationNativeFixture()
        defer { fixture.stop() }
        try await verifyCalendarEntrypoints(fixture)
        let controller = NSHostingController(rootView: MeetingPreparationView(model: fixture.model))
        let window = show(controller, size: NSSize(width: 900, height: 820))
        defer { window.close(); window.contentViewController = nil }
        try await until { fixture.model.state == .ready && !fixture.model.isLoading }
        try await settle(window)
        window.appearance = NSAppearance(named: .aqua)
        try await settle(window)
        try capture(controller.view, name: "meeting-preparation-wide")
        #expect(fixture.model.sections.count == 1)
        #expect(fixture.model.trackedWork.first?.record.title == "Corrected rollout checklist")
        #expect(fixture.model.trackedWork.first?.record.status == .completed)

        let section = try #require(fixture.model.sections.first)
        let citation = try await reveal("meeting-citation-\(section.id)-summary-0", in: controller.view, window: window)
        try #require(press(citation))
        #expect(fixture.opened?.messageID == "m1")
        let suggestion = try #require(section.suggestions.first)
        let track = try await reveal("meeting-track-\(suggestion.id)", in: controller.view, window: window)
        try #require(press(track))
        #expect(fixture.accepted?.source.messageID == "m2")
        #expect(fixture.accepted?.title == "Confirm the rollout owner")

        let file = try #require(fixture.model.recentFiles.first)
        let fileSource = try await reveal("meeting-file-source-\(file.id)", in: controller.view, window: window)
        try #require(press(fileSource))
        #expect(fixture.opened?.messageID == "m1")
        try await scroll(controller.view, window: window, offset: .greatestFiniteMagnitude)
        try capture(controller.view, name: "meeting-preparation-evidence")
        let preview = try await reveal("meeting-file-\(file.id)", in: controller.view, window: window)
        try #require(press(preview))
        try await until { fixture.previewed?.id == file.source.id }

        let source = try #require(fixture.model.sources.first)
        let exclude = try await reveal("meeting-source-action-\(source.id)", in: controller.view, window: window)
        try #require(press(exclude))
        try await until { fixture.model.sources.first?.isExcluded == true && !fixture.model.isLoading }
        #expect(fixture.model.sections.isEmpty)
        #expect(fixture.model.recentFiles.isEmpty)
        let excluded = try await reveal("meeting-excluded-sources", in: controller.view, window: window)
        try #require(press(excluded))
        let restore = try await reveal("meeting-source-action-\(source.id)", in: controller.view, window: window)
        try #require(press(restore))
        try await until { fixture.model.sections.count == 1 && !fixture.model.isLoading }

        let include = try await reveal("meeting-include-conversation", in: controller.view, window: window)
        try #require(press(include))
        try await until { window.attachedSheet?.contentView.map { element("meeting-source-search", in: $0) != nil } ?? false }
        let sheet = try #require(window.attachedSheet)
        let searchView = try #require(sheet.contentView)
        let searchField = try #require(descendants(searchView).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        sheet.makeFirstResponder(searchField)
        searchField.selectText(nil)
        let fieldEditor = try #require(sheet.fieldEditor(true, for: searchField) as? NSTextView)
        fieldEditor.string = "risk"
        fieldEditor.didChangeText()
        try await until { fixture.model.sourceSearchText == "risk" }
        try await until {
            element("meeting-source-search-submit", in: searchView)
                .map { attribute("accessibilityEnabled", of: $0) as? Bool == true } ?? false
        }
        let searchButton = try #require(element("meeting-source-search-submit", in: searchView))
        try #require(press(searchButton))
        try await until { fixture.model.searchResults.count == 1 && !fixture.model.isSearching }
        let result = try #require(fixture.model.searchResults.first)
        try await settle(sheet)
        try capture(searchView, name: "meeting-source-picker")
        let add = try #require(element("meeting-source-action-\(result.id)", in: searchView))
        try #require(press(add))
        try await until { fixture.model.sources.contains { $0.key == result.key && !$0.isExcluded } && !fixture.model.isLoading }
        let done = try #require(element("meeting-source-picker-done", in: searchView))
        try #require(press(done))
        try await until { window.attachedSheet == nil }
        #expect(fixture.model.sections.count == 2)

        fixture.providerUnavailable = true
        let refresh = try #require(element("meeting-refresh", in: controller.view))
        try #require(press(refresh))
        try await until { fixture.model.state == .providerUnavailable && !fixture.model.isLoading }
        window.setContentSize(NSSize(width: 560, height: 720))
        window.appearance = NSAppearance(named: .darkAqua)
        try await scroll(controller.view, window: window, offset: 0)
        try capture(controller.view, name: "meeting-preparation-narrow-provider-unavailable")
        #expect(fixture.model.sections.isEmpty)
        #expect(fixture.model.sources.count == 2)
        #expect(fixture.model.trackedWork.first?.record.status == .completed)
        #expect(element("meeting-settings", in: controller.view) != nil)
    }

    private func verifyCalendarEntrypoints(_ fixture: MeetingPreparationNativeFixture) async throws {
        let owner = CalendarDisplayCalendar(entry: .init(id: "calendar", summary: "Work", accessRole: "owner"),
            accountID: "a", accountName: "Work")
        var draft = CalendarEditorDraft(event: fixture.event.event, calendarKey: owner.id, source: fixture.event)
        draft.event.summary = "Unsaved review title"
        var opened: [CalendarDisplayEvent] = []
        var saves = 0
        let editor = NSHostingController(rootView: CalendarEventEditor(draft: draft, calendars: [owner], calendar: .current) { _ in
            saves += 1
        }.environment(\.prepareForMeeting, { opened.append($0) }))
        let window = show(editor, size: NSSize(width: 600, height: 720))
        defer { window.close(); window.contentViewController = nil }
        try await settle(window)
        let prepare = try #require(element("calendar.prepare-meeting", in: editor.view))
        try #require(press(prepare))
        #expect(opened.first == fixture.event)
        #expect(opened.first?.title != draft.event.summary)
        #expect(saves == 0)

        let menu = NSHostingController(rootView: VStack {
            CalendarEventMenuItems(event: fixture.event, edit: { _ in }, duplicate: { _ in }, delete: { _ in })
        }.padding().environment(\.prepareForMeeting, { opened.append($0) }))
        window.contentViewController = menu
        try await settle(window)
        let menuAction = try #require(accessibilityObjects(menu.view).first {
            [attribute("accessibilityTitle", of: $0), attribute("accessibilityLabel", of: $0)]
                .contains { $0 as? String == "Prepare for Meeting" }
                && attribute("accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue
        })
        try #require(press(menuAction))
        #expect(opened == [fixture.event, fixture.event])
        #expect(saves == 0)
    }

    private func show<V: View>(_ controller: NSHostingController<V>, size: NSSize) -> NSWindow {
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.setContentSize(size); window.makeKeyAndOrderFront(nil); NSApp.activate()
        return window
    }
    private func reveal(_ id: String, in view: NSView, window: NSWindow) async throws -> NSObject {
        try await scroll(view, window: window, offset: 0)
        for step in 0..<16 {
            if let value = element(id, in: view) { return value }
            try await scroll(view, window: window, offset: CGFloat(step + 1) * window.contentLayoutRect.height / 2)
        }
        return try #require(element(id, in: view))
    }
    private func scroll(_ view: NSView, window: NSWindow, offset: CGFloat) async throws {
        if let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, max(0, document.bounds.height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await settle(window)
    }
    private func settle(_ window: NSWindow) async throws {
        window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
    }
    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func accessibilityObjects(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let children = attribute("accessibilityChildren", of: object) as? [NSObject] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children).compactMap({ $0 as? NSObject })
                + ((object as? NSView)?.subviews ?? []) { visit(child) }
        }
        visit(root); return result
    }
    private func attribute(_ name: String, of object: NSObject) -> Any? {
        let getter = name == "accessibilityEnabled" ? "isAccessibilityEnabled" : name
        if object.responds(to: NSSelectorFromString(getter)), let value = object.value(forKey: name) { return value }
        let attributes: [String: NSAccessibility.Attribute] = ["accessibilityChildren": .children, "accessibilityIdentifier": .identifier,
            "accessibilityRole": .role, "accessibilityEnabled": .enabled, "accessibilityTitle": .title]
        guard let key = attributes[name], object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return object.accessibilityAttributeValue(key)
    }
    private func element(_ id: String, in root: NSView) -> NSObject? {
        let matches = accessibilityObjects(root).filter { attribute("accessibilityIdentifier", of: $0) as? String == id }
        return matches.first { attribute("accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue } ?? matches.first
    }
    private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        for candidate in accessibilityObjects(object) {
            if candidate.responds(to: selector), let implementation = candidate.method(for: selector) {
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(implementation, to: Press.self)(candidate, selector) { return true }
            }
            if candidate.responds(to: NSSelectorFromString("accessibilityActionNames")), candidate.accessibilityActionNames().contains(.press),
               candidate.responds(to: NSSelectorFromString("accessibilityPerformAction:")) {
                candidate.accessibilityPerformAction(.press); return true
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

@MainActor private final class MeetingPreparationNativeFixture {
    let store: AccountStore
    let event = CalendarDisplayEvent(event: GoogleCalendarEvent(id: "review", summary: "Orion migration review",
        start: .init(date: "2026-11-05"), end: .init(date: "2026-11-07")), accountID: "a", calendarID: "calendar",
        fallbackTimeZoneID: "Europe/Vienna")
    var providerUnavailable = false
    var opened: MailLink?
    var previewed: AssistantSource?
    var accepted: FollowUpSuggestionRequest?
    lazy var followUps = FollowUpsModel(store: { self.store }, visibleAccountIDs: { ["a"] }, canReadAccount: { _ in false },
        loadThread: { _, _ in throw FollowUpModelError.unavailable }, prepareDraft: { _ in throw FollowUpModelError.unavailable }, openMail: { _ in },
        scheduler: SilentFollowUpNotificationScheduler())
    lazy var model = makeModel()

    init() async throws {
        store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "a", email: "alex@example.invalid", displayName: "Work", grantedScopes: [], addedAt: .distantPast))
        let saved = try await store.createCommitment(CommitmentRecord(accountID: "a", id: "corrected", threadID: "orion", sourceMessageID: "m1",
            sourceMessageDate: .now, sourceSubject: "Orion rollout", title: "Corrected rollout checklist", ownerName: "Alex", direction: .owedByMe))
        _ = try await store.setCommitmentStatus(accountID: "a", id: "corrected", status: .completed, expectedRevision: saved.record.revision)
        await followUps.refresh(checkReminders: false)
    }
    private func makeModel() -> MeetingPreparationModel {
        MeetingPreparationModel(event: event, followUps: followUps, store: { self.store }, mailAccountIDs: { ["a"] },
            access: { _ in self.access }, makeSession: { _, _, token in
                MeetingPreparationSession(access: self.access,
                    providerUnavailableMessage: self.providerUnavailable ? "Connect an assistant provider in Settings to prepare summaries." : nil,
                    isValid: token.isCurrent, discover: { _, included, linked, excluded in
                        var seen = Set<String>()
                        let candidates = (linked + included).filter { !excluded.contains(.init(accountID: $0.accountID, threadID: $0.threadID)) && seen.insert($0.threadID).inserted }
                            .map { self.candidate($0.threadID) }
                        return .init(candidates: candidates, omittedCount: 0, hasMoreSearchResults: false, requiresManualSelection: false, failures: [])
                    }, summarize: { try self.report($0) })
            }, readEvent: { $0 }, sourceLinks: { _ in
                [.init(accountID: "a", calendarID: "calendar", eventID: "review", threadID: "orion", messageID: "m1")]
            }, sourceTitles: { keys in
                Dictionary(uniqueKeysWithValues: keys.map { ($0, self.candidate($0.threadID).title) })
            }, search: { _, _ in
                let candidate = self.candidate("risks")
                return [.init(key: candidate.thread, link: candidate.source, title: candidate.title, reason: "Matches your search.",
                    isExcluded: false, isExplicitlyIncluded: false, unavailableMessage: nil)]
            }, threadRevision: { _ in "current" }, openMail: { self.opened = $0 }, previewFile: { source in
                self.previewed = source
                throw MeetingPreparationServiceError.sourceUnavailable
            }, acceptSuggestion: { self.accepted = $0 })
    }
    private var access: MeetingPreparationAccess {
        .init(scope: .init(accountIDs: ["a"], threadIDs: nil, accountInstances: ["a": "fixture"], connectionRevision: 1, canUsePlan: true,
            calendarScope: .init(access: [.init(accountID: "a", calendarID: "calendar"): .details], revision: 1)),
            modelID: "fixture", modelReady: true, permissionRevision: 1, mailboxRuntime: "fixture")
    }
    private func candidate(_ thread: String) -> MeetingPreparationCandidate {
        .init(thread: .init(accountID: "a", threadID: thread), title: thread == "orion" ? "Orion rollout" : "Orion risk register",
            reason: thread == "orion" ? .eventLink : .included, source: .init(accountID: "a", threadID: thread, messageID: "m1"))
    }
    private func report(_ candidate: MeetingPreparationCandidate) throws -> MeetingPreparationThreadReport {
        let thread = candidate.thread.threadID
        let sources = ["m1", "m2"].map { AssistantSource(accountID: "a", threadID: thread, messageID: $0, partID: nil, title: candidate.title) }
        let data: [String: Any] = ["summary": "The team agreed to stage the migration and review the remaining risks.", "source_ids": [sources[0].id],
            "decisions": [["text": "Start with the internal pilot.", "source_ids": [sources[0].id]]],
            "open_tasks": [["description": "Confirm the rollout owner", "owner": "Jordan", "due_date": "2026-11-09", "source_ids": [sources[1].id]]]]
        let summary = try AssistantSummary.decode(JSONSerialization.data(withJSONObject: data), allowedSourceIDs: Set(sources.map(\.id)))
        let messages = ["m1", "m2"].map { id in MessageDetail(record: MessageRecord(accountID: "a", id: id, threadID: thread, historyID: 1,
            date: .now, snippet: "Review the rollout.", sender: "Jordan", recipients: "Alex", cc: nil, subject: candidate.title, sizeEstimate: 10),
            labels: [SystemLabel.inbox], body: nil, attachments: []) }
        let detail = ThreadDetail(thread: ThreadRecord(accountID: "a", id: thread, lastDate: .now, subject: candidate.title,
            snippet: "Review the rollout.", participants: "Jordan", messageCount: 2, isUnread: false, isStarred: false), messages: messages)
        let file = MeetingPreparationAttachment(source: .init(accountID: "a", threadID: thread, messageID: "m1", partID: "notes", title: "Review notes.txt"),
            filename: "Review notes.txt", sender: "Jordan", date: .now, size: 1200, mimeType: "text/plain")
        return .init(candidate: candidate, report: .init(summary: summary, sources: sources, hasPartialCoverage: true, messageIDs: ["m1", "m2"], totalMessages: 2),
            detail: detail, revision: "current", attachments: [file])
    }
    func stop() { model.stop(); followUps.stop() }
}
