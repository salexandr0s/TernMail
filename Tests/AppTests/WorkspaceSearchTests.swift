import AppKit
import MailStore
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import Tern

/// Unordered native hosts exercise focus requests without activating a window.
@Suite(.serialized) @MainActor struct WorkspaceSearchTests {
    private let mailOwner = NSObject()
    private let calendarOwner = NSObject()
    private let attachmentOwner = NSObject()

    @Test
    func switchingSourcesPreservesFieldWithoutRequestingFocus() async throws {
        let host = NSHostingView(rootView: item(section: .mail, request: 0, text: "mail query"))
        let window = makeWindow(host: host)
        defer { window.close() }
        await settle(host)
        let field = try #require(searchFields(in: host).first)
        let initialRequests = window.searchFocusRequests

        host.rootView = item(section: .mail, request: 1, text: "mail query")
        await settle(host)
        #expect(window.searchFocusRequests > initialRequests, "Explicit Mail Find must reach the native field")
        let mailRequests = window.searchFocusRequests

        host.rootView = item(section: .calendar, request: 0, text: "event query")
        await settle(host)
        #expect(searchFields(in: host).first === field, "The test must update the same native search field")
        #expect(window.searchFocusRequests == mailRequests)
        #expect(field.stringValue == "event query")

        // Existing callers issue Find for the active model. An explicit request
        // after switching must still work, even with a lower section counter.
        host.rootView = item(section: .calendar, request: 1, text: "event query")
        await settle(host)
        #expect(window.searchFocusRequests > mailRequests)
        let calendarRequests = window.searchFocusRequests
        host.rootView = item(section: .attachments, request: 99, text: "attachment query")
        await settle(host)
        #expect(window.searchFocusRequests == calendarRequests,
            "A larger historical counter from another source is not a Find request either")
        #expect(field.stringValue == "attachment query")

        host.rootView = item(section: .attachments, request: 100, text: "attachment query")
        await settle(host)
        #expect(window.searchFocusRequests > calendarRequests)
        let attachmentRequests = window.searchFocusRequests
        host.rootView = item(section: .mail, request: 1, text: "mail query")
        await settle(host)
        #expect(window.searchFocusRequests == attachmentRequests)
        #expect(searchFields(in: host).first === field)
        #expect(field.stringValue == "mail query")
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test
    func foldedSearchOpensOnlyForItsOwnRequestsAndResetsForNewOwner() async throws {
        let host = NSHostingView(rootView: item(section: .mail, request: 1, folded: true))
        let window = makeWindow(host: host)
        // A refused focus request produces no editor to send didEndEditing.
        // Source cleanup must therefore work independently of that callback.
        window.acceptsSearchFocusRequests = false
        defer { window.close() }
        await settle(host)
        #expect(searchFields(in: host).isEmpty)
        let initialRequests = window.searchFocusRequests

        host.rootView = item(section: .calendar, request: 0, folded: true)
        await settle(host)
        #expect(searchFields(in: host).isEmpty)
        #expect(window.searchFocusRequests == initialRequests)

        host.rootView = item(section: .calendar, request: 1, folded: true)
        await settle(host)
        #expect(searchFields(in: host).count == 1)
        #expect(window.searchFocusRequests > initialRequests)
        let firstRequest = window.searchFocusRequests

        host.rootView = item(section: .mail, request: 1, folded: true)
        await settle(host)
        #expect(searchFields(in: host).isEmpty)
        host.rootView = item(section: .calendar, request: 1, folded: true)
        await settle(host)
        #expect(searchFields(in: host).isEmpty,
            "Returning to a previously opened source must not replay its earlier Find")
        #expect(window.searchFocusRequests == firstRequest)
        host.rootView = item(section: .calendar, request: 2, folded: true)
        await settle(host)
        #expect(searchFields(in: host).count == 1)
        #expect(window.searchFocusRequests > firstRequest)
        let requested = window.searchFocusRequests

        // A replaced account/model must not inherit the old model's open state
        // even when the section and generation happen to match.
        let replacement = NSObject()
        host.rootView = item(section: .calendar, request: 2, folded: true, owner: replacement)
        await settle(host)
        #expect(searchFields(in: host).isEmpty)
        #expect(window.searchFocusRequests == requested)
        host.rootView = item(section: .calendar, request: 3, folded: true, owner: replacement)
        await settle(host)
        #expect(searchFields(in: host).count == 1)
        #expect(window.searchFocusRequests > requested)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test
    func searchChangesUpdateContentWithoutInvalidatingToolbarDeclaration() async throws {
        let suite = "WorkspaceSearchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountRecord(id: "search-observation", email: "search@example.invalid",
            displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: try MailCache.inMemory(), gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory, syncEnabled: false,
            listPreferences: MessageListPreferences(defaults: defaults))
        let calendar = CalendarModel(app: nil, defaults: defaults)
        let library = AttachmentLibraryToolbarState()
        for section in WorkspaceSection.allCases {
            let toolbar = WorkspaceSearchToolbar(mailbox: mailbox, calendar: calendar,
                libraryToolbar: library, section: section)
            let content = WorkspaceSearchContent(mailbox: mailbox, calendar: calendar,
                libraryToolbar: library, section: section)
            let textCount = invalidations(parent: { _ = toolbar.body }, leaf: { _ = content.body }) {
                switch section {
                case .mail: mailbox.search.update("synthetic")
                case .calendar: calendar.searchText = "synthetic"
                case .attachments: library.searchText = "synthetic"
                }
            }
            #expect(textCount.parent == 0)
            #expect(textCount.leaf == 1)
            let focusCount = invalidations(parent: { _ = toolbar.body }, leaf: { _ = content.body }) {
                switch section {
                case .mail: mailbox.search.focusField()
                case .calendar: calendar.searchFocusRequest += 1
                case .attachments: library.searchFocusRequest += 1
                }
            }
            #expect(focusCount.parent == 0)
            #expect(focusCount.leaf == 1)
            #expect(invalidations(tracking: { _ = toolbar.body }) {
                mailbox.notice = .init(message: "Unrelated synthetic notice")
            } == 0)
        }
        await mailbox.stop()
    }

    private func item(section: WorkspaceSection, request: Int, folded: Bool = false,
                      text: String = "", owner: AnyObject? = nil) -> WorkspaceSearchItem {
        let defaultOwner: NSObject = switch section {
        case .mail: mailOwner
        case .calendar: calendarOwner
        case .attachments: attachmentOwner
        }
        return WorkspaceSearchItem(placeholder: "Search \(section.rawValue)", text: text,
            focusRequest: .init(section: section, owner: owner ?? defaultOwner, generation: request),
            width: 200, canFold: folded,
            onChange: { _ in }, onSubmit: {}, onCancel: {})
    }

    private func makeWindow(host: NSView) -> SearchRequestWindow {
        let window = SearchRequestWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func searchFields(in view: NSView) -> [NSSearchField] {
        (view as? NSSearchField).map { [$0] } ?? view.subviews.flatMap { searchFields(in: $0) }
    }

    private func invalidations(tracking read: () -> Void, mutate: () -> Void) -> Int {
        let callbacks = Mutex(0)
        withObservationTracking(read) { callbacks.withLock { $0 += 1 } }
        mutate()
        return callbacks.withLock { $0 }
    }

    private func invalidations(parent: () -> Void, leaf: () -> Void,
                               mutate: () -> Void) -> (parent: Int, leaf: Int) {
        let parentCallbacks = Mutex(0)
        let leafCallbacks = Mutex(0)
        withObservationTracking(parent) { parentCallbacks.withLock { $0 += 1 } }
        withObservationTracking(leaf) { leafCallbacks.withLock { $0 += 1 } }
        mutate()
        return (parentCallbacks.withLock { $0 }, leafCallbacks.withLock { $0 })
    }
}

@MainActor private final class SearchRequestWindow: NSWindow {
    private(set) var searchFocusRequests = 0
    var acceptsSearchFocusRequests = true

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSSearchField {
            searchFocusRequests += 1
            if !acceptsSearchFocusRequests { return false }
        }
        return super.makeFirstResponder(responder)
    }
}
