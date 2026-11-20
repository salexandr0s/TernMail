import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct WorkspaceToolbarLayoutTests {
    private let sidebars = WorkspaceToolbarLayout.Sidebars(
        mail: Tokens.Layout.sidebarWidth + Tokens.Layout.columnGutter,
        calendar: Tokens.Calendar.sidebarWidth, attachments: Tokens.Layout.sidebarWidth)

    @Test func controlsFoldInOrderAsTheWindowNarrows() {
        func layout(_ section: WorkspaceSection, _ width: CGFloat, sidebars: WorkspaceToolbarLayout.Sidebars? = nil,
                    profileNameWidth: CGFloat? = nil, labels: Bool = false) -> WorkspaceToolbarLayout {
            WorkspaceToolbarLayout(section: section, width: width, sidebars: sidebars ?? self.sidebars,
                profileNameWidth: profileNameWidth, labels: labels)
        }
        // The default window names the mailbox and keeps the search field, with mail's actions in menus.
        let standard = layout(.mail, Tokens.Layout.windowWidth)
        #expect(standard.showsTitle && standard.compactActions && !standard.foldsSearch && !standard.foldsReplies)
        // Expanded actions come before the title.
        let wide = layout(.mail, 1_440)
        #expect(!wide.compactActions && !wide.showsTitle && !wide.foldsSearch)
        #expect(layout(.mail, 1_600).showsTitle)
        // Search folds in every section once one section runs out of room, so it never moves on a switch.
        for section in WorkspaceSection.allCases {
            #expect(!layout(section, 1_100).foldsSearch && layout(section, 1_000).foldsSearch)
        }
        // A section keeps its folded actions beside its sidebar down to the width where the sidebar steps aside.
        #expect(!layout(.mail, 908).foldsReplies && !layout(.calendar, 937).foldsCalendarToday)
        #expect(WorkspaceToolbarLayout.sidebarRoom(for: .mail, width: 908) == sidebars.mail)
        #expect(WorkspaceToolbarLayout.sidebarRoom(for: .calendar, width: 937) == sidebars.calendar)
        #expect(WorkspaceToolbarLayout.sidebarRoom(for: .attachments, width: 790) == sidebars.attachments)
        // Without a sidebar the narrowest window folds each section's last groups into its menu.
        let none = WorkspaceToolbarLayout.Sidebars()
        let narrow = Tokens.Layout.windowMinWidth
        #expect(layout(.mail, narrow, sidebars: none).foldsReplies)
        #expect(!layout(.mail, narrow, sidebars: none).foldsProfile)
        #expect(layout(.mail, narrow, sidebars: none, profileNameWidth: 40).foldsProfile)
        #expect(!layout(.today, narrow, sidebars: none, profileNameWidth: 40).foldsProfile)
        let calendar = layout(.calendar, narrow, sidebars: none)
        #expect(calendar.foldsCalendarToday && calendar.foldsCalendarNavigation)
        #expect(!layout(.calendar, 800, sidebars: none).foldsCalendarToday)
        // A profile's name waits for a wide window and for room beside mail's expanded actions.
        #expect(layout(.mail, 1_440, profileNameWidth: 40).compactProfile == false)
        #expect(layout(.mail, 1_440, profileNameWidth: 200).compactProfile)
        #expect(layout(.today, 1_280, profileNameWidth: 40).compactProfile)
        // Labels widen the items. The default window folds the search field, and Mail's sidebar steps aside
        // before the replies fold.
        let window = Tokens.Layout.windowWidth
        #expect(layout(.mail, window, labels: true).foldsSearch)
        #expect(WorkspaceToolbarLayout.sidebarRoom(for: .mail, width: window, labels: true) < sidebars.mail)
        #expect(!layout(.mail, window, sidebars: none, labels: true).foldsReplies)
    }

    /// AppKit moves the items that don't fit a toolbar into its overflow menu,
    /// Assistant and Tasks first. This lays the real toolbar out at each width,
    /// in Icon Only and in Icon and Text mode, and fails when the layout's
    /// measured widths no longer match AppKit's.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func everyControlStaysInTheToolbarAtEveryWidth(labels: Bool) async throws {
        let toolbar = try await ToolbarWindow(width: 1_280, height: 760)
        defer { toolbar.close() }
        let window = toolbar.window
        try await toolbar.showLabels(labels)

        // Narrowing and then widening covers each sidebar stepping aside and coming back.
        for width in [CGFloat(1_440), 1_280, 1_200, 1_100, 1_000, 900, 800, 720, 1_000, 1_280] {
            window.setContentSize(NSSize(width: width, height: 760))
            for section in WorkspaceSection.allCases {
                toolbar.show(section)
                guard !labels || width >= narrowestWidthWithLabels(for: section) else { continue }
                try await expectControls(for: section, in: window, width: width)
            }
        }

        // The profile picker joins Mail, Waiting for and Today once a profile exists.
        let accounts = try #require(toolbar.app.accountPreferences)
        try #require(await accounts.saveProfile(MailProfile(name: "Consulting clients")))
        await accounts.refresh()
        try #require(!accounts.profiles.isEmpty)
        for width in [CGFloat(1_600), 1_440, 1_280, 1_000, 800, 720] {
            window.setContentSize(NSSize(width: width, height: 760))
            for section in [WorkspaceSection.mail, .today] {
                toolbar.show(section)
                guard !labels || width >= narrowestWidthWithLabels(for: section, profile: true) else { continue }
                let folds = WorkspaceToolbarLayout(section: section, width: width, profileNameWidth: 0,
                    labels: labels).foldsProfile
                try await expectControls(for: section, in: window, width: width, profile: !folds)
            }
        }
        await toolbar.app.signOut()
    }

    /// The narrowest window that holds every control of `section` with labels
    /// once the layout has folded all it can and no sidebar shows, by the
    /// layout's widths. In a narrower one the overflow menu takes the trailing
    /// controls. Without labels every section fits the narrowest window.
    private func narrowestWidthWithLabels(for section: WorkspaceSection, profile: Bool = false) -> CGFloat {
        let picker: CGFloat = profile ? 99 : 0
        return switch section {
        // Mail's picker joins its menu.
        case .mail: 1_050
        case .attachments: 921
        case .calendar: 822
        case .followUps: 690 + picker
        case .today: 666 + picker
        }
    }

    /// AppKit gives a toolbar's new display mode to every toolbar with the
    /// same identifier but reports it only for the toolbar that changed, so
    /// the other windows have to notice it too.
    @Test func everyWindowFollowsADisplayModeChange() async throws {
        let identifier = "\(MailWindowPreferences.toolbarID).\(UUID().uuidString)"
        let windows = (0..<2).map { _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbar = NSToolbar(identifier: identifier)
            window.orderBack(nil)
            return window
        }
        defer {
            for window in windows {
                window.close()
                window.toolbar = nil
            }
        }
        let modes = windows.map { window in
            let mode = ToolbarDisplayMode()
            mode.follow(window)
            return mode
        }
        for (changed, labels) in [(0, true), (1, false)] {
            windows[changed].toolbar?.displayMode = labels ? .iconAndLabel : .iconOnly
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while modes.contains(where: { $0.showsLabels != labels }) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(modes.map(\.showsLabels) == [labels, labels])
        }
    }

    /// Switching to Calendar stopped the app in a layout pass of the toolbar,
    /// most often when the click on the section picker also made the window
    /// key. This switches to Calendar from the other sections while the window
    /// becomes key, at the size of the first report and at the eight widest
    /// widths where a toolbar folds a control, in both display modes. With
    /// Sidebar and Refresh as two items, it stopped the app in two runs, at
    /// the 7th and the 11th switch.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func switchingToCalendarWhileTheWindowBecomesKeyLaysOut(labels: Bool) async throws {
        let height: CGFloat = 1_073
        let toolbar = try await ToolbarWindow(width: 1_162, height: height)
        defer { toolbar.close() }
        try await toolbar.showLabels(labels)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NSApp.activate()
        let settle = Duration.milliseconds(200)
        for width in [1_162] + foldingWidths(labels: labels).prefix(8) {
            for source in [WorkspaceSection.mail, .followUps, .today, .attachments] {
                toolbar.window.setContentSize(NSSize(width: width, height: height))
                toolbar.window.makeKeyAndOrderFront(nil)
                toolbar.show(source)
                try await Task.sleep(for: settle)
                other.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: settle)
                toolbar.show(.calendar)
                toolbar.window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: settle)
                // Calendar's items can take longer than the settle time to show,
                // as on the first switch of one full run, so wait up to 3 seconds.
                var items = toolbar.itemIdentifiers
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !items.contains("calendar.mode") && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                    items = toolbar.itemIdentifiers
                }
                #expect(items.contains("calendar.mode"),
                    "Calendar's toolbar is missing after a switch from \(source.title) at \(Int(width)) points: \(items)")
            }
        }
        await toolbar.app.signOut()
    }

    /// Widths where Mail's or Calendar's toolbar folds or unfolds a control,
    /// with their sidebars and without, each with the width a point narrower.
    private func foldingWidths(labels: Bool) -> [CGFloat] {
        var widths: Set<CGFloat> = []
        for shown in [sidebars, WorkspaceToolbarLayout.Sidebars()] {
            for section in [WorkspaceSection.mail, .calendar] {
                var previous: WorkspaceToolbarLayout?
                for width in stride(from: Tokens.Layout.windowMinWidth, through: 1_600, by: 1) {
                    let layout = WorkspaceToolbarLayout(section: section, width: width, sidebars: shown,
                        labels: labels)
                    if let previous, previous != layout { widths.formUnion([width - 1, width]) }
                    previous = layout
                }
            }
        }
        return widths.sorted(by: >)
    }

    /// Waits for the toolbar to settle, then checks that the section's controls
    /// and the shared trailing ones are all in the toolbar and inside the window.
    private func expectControls(for section: WorkspaceSection, in window: NSWindow, width: CGFloat,
                                profile: Bool = false) async throws {
        var required = ["workspace.refresh", "workspace.destination", "workspace.search", "workspace.tasks",
                        "workspace.assistant"]
        switch section {
        case .mail: required += ["mail.compose", "mail.archive", "mail.trash"]
        case .calendar: required += ["mail.compose", "calendar.mode"]
        case .attachments: required += ["mail.compose"]
        case .followUps, .today: break
        }
        if profile { required.append("mail.profile") }
        let anyOf: [String] = switch section {
        case .mail: ["mail.more", "mail.compactActions"]
        case .attachments: ["library.sort", "library.compactOptions"]
        case .calendar, .followUps, .today: []
        }

        var frames: [(id: String, frame: NSRect)] = []
        func settled() -> Bool {
            let visible = Set(frames.map(\.id))
            return required.allSatisfy(visible.contains) && (anyOf.isEmpty || anyOf.contains(where: visible.contains))
                && frames.allSatisfy { $0.frame.minX >= -1 && $0.frame.maxX <= width + 1 }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        var stable = 0
        repeat {
            try await Task.sleep(for: .seconds(Tokens.Motion.slow + Tokens.Motion.fast))
            let current: [(id: String, frame: NSRect)] = (window.toolbar?.visibleItems ?? []).compactMap { item in
                guard let view = item.view, view.window === window else { return nil }
                return (item.itemIdentifier.rawValue, view.convert(view.bounds, to: nil))
            }
            // Two equal readings in a row, so a sidebar's slide has finished.
            let same = current.map(\.id) == frames.map(\.id)
                && zip(current, frames).allSatisfy { abs($0.frame.minX - $1.frame.minX) <= 0.5 }
            stable = same ? stable + 1 : 0
            frames = current
        } while !(settled() && stable >= 1) && ContinuousClock.now < deadline

        let found = frames.map { "\($0.id)@\(Int($0.frame.minX))+\(Int($0.frame.width))" }.joined(separator: " ")
        let visible = Set(frames.map(\.id))
        for identifier in required {
            #expect(visible.contains(identifier), "\(identifier) left the \(section.rawValue) toolbar at \(Int(width)) points: \(found)")
        }
        if !anyOf.isEmpty {
            #expect(anyOf.contains(where: visible.contains),
                "The \(section.rawValue) actions left the toolbar at \(Int(width)) points: \(found)")
        }
        for item in frames {
            #expect(item.frame.minX >= -1 && item.frame.maxX <= width + 1,
                "\(item.id) runs past the window in \(section.rawValue) at \(Int(width)) points: \(found)")
        }
    }
}

/// The workspace with its real toolbar in a window of its own, and settings
/// that last for one test.
@MainActor private final class ToolbarWindow {
    let app: AppModel
    let window: NSWindow
    private let mailbox: MailboxModel
    private let settings: UserDefaults
    private let suite: String

    init(width: CGFloat, height: CGFloat) async throws {
        let app = AppModel()
        await app.start()
        await app.calendar.seedCalendarAudit()
        let mailbox = try #require(app.mailbox)
        let suite = "WorkspaceToolbarLayoutTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        let identifier = "\(MailWindowPreferences.toolbarID).\(UUID().uuidString)"
        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, identifier).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.orderBack(nil)
        self.app = app
        self.window = window
        self.mailbox = mailbox
        self.settings = settings
        self.suite = suite
    }

    /// The identifiers of the items the toolbar shows, in order.
    var itemIdentifiers: [String] {
        window.toolbar?.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
    }

    /// Shows or hides the labels under the toolbar's items once SwiftUI has
    /// given the window its toolbar.
    func showLabels(_ labels: Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while window.toolbar == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let toolbar = try #require(window.toolbar)
        toolbar.displayMode = labels ? .iconAndLabel : .iconOnly
    }

    func show(_ section: WorkspaceSection) {
        switch section {
        case .mail:
            app.destination = .mail
            mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        case .attachments:
            app.destination = .mail
            mailbox.showAttachmentLibrary()
        case .calendar: app.destination = .calendar
        case .followUps: app.destination = .followUps
        case .today: app.destination = .today
        }
    }

    func close() {
        window.close()
        window.contentViewController = nil
        window.toolbar = nil
        settings.removePersistentDomain(forName: suite)
    }
}
