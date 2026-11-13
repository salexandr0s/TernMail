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
                    profileNameWidth: CGFloat? = nil) -> WorkspaceToolbarLayout {
            WorkspaceToolbarLayout(section: section, width: width, sidebars: sidebars ?? self.sidebars,
                profileNameWidth: profileNameWidth)
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
    }

    /// AppKit moves the items that don't fit a toolbar into its overflow menu,
    /// Assistant and Tasks first. This lays the real toolbar out at each width
    /// and fails when the layout's measured widths no longer match AppKit's.
    @Test(.timeLimit(.minutes(3))) func everyControlStaysInTheToolbarAtEveryWidth() async throws {
        let app = AppModel()
        await app.start()
        await app.calendar.seedCalendarAudit()
        let mailbox = try #require(app.mailbox)
        let suite = "WorkspaceToolbarLayoutTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let identifier = "\(MailWindowPreferences.toolbarID).\(UUID().uuidString)"
        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, identifier).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }

        func show(_ section: WorkspaceSection) {
            switch section {
            case .mail:
                app.destination = .mail
                mailbox.selectedMailbox = .combined(SystemLabel.inbox)
            case .attachments:
                app.destination = .mail
                mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
            case .calendar: app.destination = .calendar
            case .followUps: app.destination = .followUps
            case .today: app.destination = .today
            }
        }

        // Narrowing and then widening covers each sidebar stepping aside and coming back.
        for width in [CGFloat(1_440), 1_280, 1_200, 1_100, 1_000, 900, 800, 720, 1_000, 1_280] {
            window.setContentSize(NSSize(width: width, height: 760))
            for section in WorkspaceSection.allCases {
                show(section)
                try await expectControls(for: section, in: window, width: width)
            }
        }

        // The profile picker joins Mail, Waiting for and Today once a profile exists.
        let accounts = try #require(app.accountPreferences)
        try #require(await accounts.saveProfile(MailProfile(name: "Consulting clients")))
        await accounts.refresh()
        try #require(!accounts.profiles.isEmpty)
        for width in [CGFloat(1_600), 1_440, 1_280, 1_000, 800, 720] {
            window.setContentSize(NSSize(width: width, height: 760))
            for section in [WorkspaceSection.mail, .today] {
                show(section)
                let folds = WorkspaceToolbarLayout(section: section, width: width, profileNameWidth: 0).foldsProfile
                try await expectControls(for: section, in: window, width: width, profile: !folds)
            }
        }
        await app.signOut()
    }

    /// Waits for the toolbar to settle, then checks that the section's controls
    /// and the shared trailing ones are all in the toolbar and inside the window.
    private func expectControls(for section: WorkspaceSection, in window: NSWindow, width: CGFloat,
                                profile: Bool = false) async throws {
        var required = ["workspace.refresh", "workspace.destination", "workspace.search", "workspace.tasks",
                        "workspace.assistant"]
        switch section {
        case .mail: required += ["workspace.sidebar", "mail.compose", "mail.archive", "mail.trash"]
        case .calendar: required += ["workspace.sidebar", "mail.compose", "calendar.mode"]
        case .attachments: required += ["workspace.sidebar", "mail.compose"]
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
