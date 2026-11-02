import AppKit
import GmailAPI
import SwiftUI
import Testing
@testable import Tern

/// Native checks for content hidden by the compact previews. These are opt-in
/// because they open windows and record synthetic screenshots for inspection.
@Suite @MainActor struct AssistantFormattingPolishAudit {
    private let audit = AssistantResultsVisualAudit()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func codeAndTableExpansionSurviveResize() async throws {
        let code = (1...14).map { "let item\($0) = \($0)" }.joined(separator: "\n")
        let rows = (1...9).map { "| Option \($0) | Review the delivery date with the team | Waiting |" }.joined(separator: "\n")
        let text = """
        ## Delivery options
        | Option | Next step | Status |
        | --- | --- | --- |
        \(rows)

        ## Reference code
        ```swift

        \(code)

        ```
        """
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await audit.capture(ScrollView {
                AssistantMarkdownView(text: text).padding(Tokens.Space.s4)
            }, size: NSSize(width: 720, height: 900), scheme: scheme, name: "long-formats-collapsed-\(suffix)") { window, view in
                #expect(audit.find("Option 9", in: view) == nil)
                #expect(audit.find("let item14", in: view) == nil)
                try await press("Show all 9 rows", in: view)
                try await press("Show all 14 lines", in: view)
                #expect(audit.find("Option 9", in: view) != nil)
                #expect(audit.find("let item14", in: view) != nil)
                try audit.attach(view, name: "long-formats-expanded-wide-\(suffix)")
                window.setContentSize(NSSize(width: 320, height: 900))
                try await Task.sleep(for: .milliseconds(200))
                view.layoutSubtreeIfNeeded()
                #expect(audit.find("Show fewer rows", in: view, needsPress: true) != nil)
                #expect(audit.find("Show fewer lines", in: view, needsPress: true) != nil)
                #expect(audit.find("Option 9", in: view) != nil)
                try audit.attach(view, name: "long-formats-expanded-narrow-\(suffix)")
                try await press("Show fewer rows", in: view)
                try await press("Show fewer lines", in: view)
                #expect(audit.find("Option 9", in: view) == nil)
                #expect(audit.find("let item14", in: view) == nil)
                try audit.attach(view, name: "long-formats-collapsed-narrow-\(suffix)")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func wrappedTableCellsDoNotOverlapFollowingRows() async throws {
        let long = "A longer explanation that wraps inside the column and keeps every delivery detail visible."
        let short = "A short follow-up."
        try await audit.capture(AssistantMarkdownView(text: """
        | Option | Notes | Decision |
        | --- | --- | --- |
        | **Morning** | \(long) | Review |
        | Afternoon | \(short) | |
        | | `Keep literal code` alongside the final decision. | Waiting |
        """).padding(Tokens.Space.s4), size: NSSize(width: 720, height: 500), scheme: .light,
            name: "table-wrapped-rows") { _, view in
            let first = try frame(long, in: view)
            let next = try frame(short, in: view)
            #expect(first.height > next.height)
            // Accessibility frames use screen coordinates, with Y increasing up.
            #expect(first.minY >= next.maxY)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func fullDiagramAndSourceRemainAvailable() async throws {
        let source = "flowchart TD\nA[Read] --> B[Review] --> C[Check] --> D[Discuss] --> E[Decide] --> F[Approve] --> G[Prepare] --> H[Send]"
        let diagram = try #require(AssistantDiagram.parse(source))
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await audit.capture(AssistantDiagramView(diagram: diagram, source: source)
                .padding(Tokens.Space.s4), size: NSSize(width: 320, height: 650), scheme: scheme,
                name: "tall-diagram-preview-\(suffix)", increasedContrast: true) { window, view in
                try await press("Open full diagram", in: view)
                let sheet = try #require(window.attachedSheet)
                let sheetView = try #require(sheet.contentView)
                #expect(audit.find("Full flowchart", in: sheetView) != nil)
                try audit.attach(sheetView, name: "tall-diagram-full-\(suffix)")
                try await press("Close", in: sheetView)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while window.attachedSheet != nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(30))
                }
                #expect(window.attachedSheet == nil)
                try await press("Show source", in: view)
                #expect(audit.find(source, in: view) != nil)
                try audit.attach(view, name: "tall-diagram-source-\(suffix)")
                try await press("Show diagram", in: view)
                #expect(audit.find("Open full diagram", in: view, needsPress: true) != nil)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func horizontalDiagramOffersFullViewUntilItFits() async throws {
        let source = "flowchart LR\nA -->|Needs review before sending| B\nA -->|Ready for immediate delivery| C"
        let diagram = try #require(AssistantDiagram.parse(source))
        try await audit.capture(AssistantDiagramView(diagram: diagram, source: source).padding(Tokens.Space.s4),
            size: NSSize(width: 320, height: 600), scheme: .light, name: "wide-diagram-preview") { window, view in
            try await press("Open full diagram", in: view)
            let sheetView = try #require(window.attachedSheet?.contentView)
            try audit.attach(sheetView, name: "wide-diagram-full")
            try await press("Close", in: sheetView)
            window.setContentSize(NSSize(width: 720, height: 600))
            try await Task.sleep(for: .milliseconds(250))
            #expect(audit.find("Open full diagram", in: view, needsPress: true) == nil)
            try audit.attach(view, name: "wide-diagram-fits")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func completeMessageKeepsCardsAndSourcesReachable() async throws {
        let app = AppModel()
        let model = AssistantModel(app: app, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
            context: { .init(accounts: [], isAccountListReady: true, currentAccountIDs: [], selectedThreads: [],
                             accountInstances: [:], connectionRevision: 0, canUsePlan: false) })
        let source = AssistantSource(accountID: "formatting-audit", threadID: "review", messageID: "m1", partID: nil,
                                     title: "Delivery plan and design reviews")
        var message = AssistantMessage(isUser: false, text: """
        ## Your week
        Review **the delivery plan** and the upcoming design sessions. Each item includes its source and details.

        - Confirm the dates before adding events.
        - Keep the final decision with the project notes.
        """, sources: [source])
        message.taskResults = (1...4).map { .init(source: source, title: "Review delivery option \($0)", owner: "Alex",
            notes: "Check the estimate before approving.", dueDate: "2026-11-06", evidence: "Please review delivery option \($0).") }
        message.eventResults = (1...4).map { index in
            var event = GoogleCalendarEvent(summary: "Design session \(index)")
            event.start = .init(dateTime: "2026-11-0\(index + 3)T10:00:00Z", timeZone: "UTC")
            event.end = .init(dateTime: "2026-11-0\(index + 3)T11:00:00Z", timeZone: "UTC")
            event.location = "Vienna office"
            return .init(source: source, event: event, evidence: "Design session \(index), 10:00–11:00 UTC.")
        }
        message.emailResults = (1...4).map { index in
            let mailSource = AssistantSource(accountID: source.accountID, threadID: "mail-\(index)", messageID: "m1",
                                            partID: nil, title: "Delivery update \(index)")
            return .init(source: mailSource, senderName: "Alex Morgan", senderEmail: "alex@example.invalid",
                subject: "Delivery update \(index)", snippet: "Please confirm the dates with the team.",
                date: Date(timeIntervalSince1970: 1_793_664_000), isUnread: index == 1, isStarred: false,
                messageCount: 2, accountEmail: "work@example.invalid", labels: [], reason: "Needs your review.")
        }
        for (width, scheme) in [(320.0, ColorScheme.dark), (720.0, .light)] {
            let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
            try await audit.capture(ScrollView {
                AssistantMessageView(message: message, startsGroup: true, status: nil, canRetry: false,
                    onRetry: {}, onOpenSource: { _ in }, onOpenSourceInNewWindow: { _ in }, onOpenDraft: { _ in }, model: model)
                    .padding(.horizontal, Tokens.Space.s4)
            }, size: NSSize(width: width, height: 980), scheme: scheme, name: "complete-message-\(suffix)",
                captureBottom: true) { _, view in
                try await press("Show all 4 tasks", in: view)
                try await press("Show all 4 events", in: view)
                try await press("Show all 4 emails", in: view)
                #expect(audit.find("Task: Review delivery option 4", in: view) != nil)
                #expect(audit.find("Event: Design session 4", in: view) != nil)
                #expect(audit.find("Delivery update 4", in: view) != nil)
                try await press("Show fewer tasks", in: view)
                try await press("Show fewer events", in: view)
                try await press("Show fewer emails", in: view)
                try await press("1 source", in: view)
                #expect(audit.find("Open source: Delivery plan and design reviews", in: view, needsPress: true) != nil)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_ASSISTANT_RESULTS_AUDIT_DIR"] != nil))
    func calendarReviewAndTimeChoicesStayCompactAndSelectable() async throws {
        let app = AppModel()
        let model = AssistantModel(app: app, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
            context: { .init(accounts: [], isAccountListReady: true, currentAccountIDs: [], selectedThreads: [],
                             accountInstances: [:], connectionRevision: 0, canUsePlan: false) })
        let calendar = AssistantCalendarKey(accountID: "formatting-audit", calendarID: "work")
        var message = AssistantMessage(isUser: false, text: "Choose a time to suggest.")
        message.calendarProposals = (1...4).map { index in
            .init(id: UUID(), calendar: calendar, title: "Design review \(index) with the product and engineering teams",
                  accessRevision: 0)
        }
        let checked = Date(timeIntervalSince1970: 1_793_664_000)
        message.availabilityChoices = (0..<8).map { index in
            let start = checked.addingTimeInterval(Double(index) * 86_400 + 32_400)
            return .init(calendarKeys: [calendar], start: start, end: start.addingTimeInterval(2_700),
                         timeZoneIdentifier: "Europe/Vienna", checkedAt: checked, accessRevision: 0)
        }
        for (width, scheme) in [(320.0, ColorScheme.dark), (380.0, .light), (720.0, .light)] {
            let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
            try await audit.capture(AssistantCalendarActionsView(message: message, model: model).padding(Tokens.Space.s4),
                size: NSSize(width: width, height: 900), scheme: scheme, name: "calendar-choices-\(suffix)") { _, view in
                if width == 320 {
                    let review = try frame("Review \(message.calendarProposals[0].title)", in: view)
                    #expect(review.height > Tokens.Space.s8)
                }
                let action = try #require(audit.find("Use selected times in a reply", in: view, needsPress: true))
                #expect(action.value(forKey: "accessibilityEnabled") as? Bool == false)
                try await press(message.availabilityChoices[0].displayTitle, in: view)
                #expect(action.value(forKey: "accessibilityEnabled") as? Bool == true)
                #expect(audit.find(message.availabilityChoices[7].displayTitle, in: view) != nil)
                try audit.attach(view, name: "calendar-choice-selected-\(suffix)")
            }
        }
    }

    private func frame(_ label: String, in view: NSView) throws -> NSRect {
        let element = try #require(audit.find(label, in: view))
        #expect(element.responds(to: NSSelectorFromString("accessibilityFrame")))
        let value = try #require(element.value(forKey: "accessibilityFrame") as? NSValue)
        #expect(value.rectValue.width > 0 && value.rectValue.height > 0)
        return value.rectValue
    }

    private func press(_ label: String, in view: NSView) async throws {
        let control = try #require(audit.find(label, in: view, needsPress: true))
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try #require(control.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        // AppKit's public -(BOOL)accessibilityPerformPress method has this ABI.
        #expect(unsafeBitCast(implementation, to: Press.self)(control, selector))
        try await Task.sleep(for: .milliseconds(180))
        view.layoutSubtreeIfNeeded()
    }
}
