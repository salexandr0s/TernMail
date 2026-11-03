import AppKit
import MailStore
import MessageContent
import SwiftUI
import Testing
import TernAI
import WebKit
@testable import Tern

@Suite(.serialized) @MainActor struct MessageHeaderInteractionTests {
    @Test func previewsRemoveOnlyLeadingBoilerplateAndBoundTheirInput() {
        #expect(MessagePreview.cleaned("  View this email in your browser.\nPlease review the route. ") == "Please review the route.")
        let quoted = "The footer says View this email in your browser. Keep it in the template."
        #expect(MessagePreview.cleaned(quoted) == quoted)
        #expect(MessagePreview.cleaned(String(repeating: "x", count: 4_096)).count == 2_048)
    }

    @Test func blockedImagesKeepStylesheetSizingAndBlockFlow() async throws {
        let html = """
            <style>td > img.hero {width:100%;display:block}</style>
            <table style="width:320px"><tr><td>
            <img class="hero" width="300" height="200" src="https://example.invalid/first.png">
            <img class="hero" width="300" height="200" src="https://example.invalid/second.png">
            </td></tr></table>
            """
        let state = ImageLayoutState()
        let reader = MessageWebView(html: MessageDocument.render(html: html).html,
            blocker: await RemoteContentBlocker.ruleList(),
            height: Binding(get: { state.height }, set: { state.height = $0 }))
        let window = makeWindow(reader, width: 400, height: 600)
        defer { window.close() }
        var geometry: [String: Double]?
        try await eventuallyAsync {
            guard let content = window.contentView,
                  let view = self.descendants(content).compactMap({ $0 as? ContentSizedWebView }).first,
                  !view.isLoading else { return false }
            geometry = try await view.evaluateJavaScript("""
                (() => {
                    const images = Array.from(document.querySelectorAll('img.hero'));
                    const cell = document.querySelector('td');
                    if (!cell || images.length !== 2 || images.some(image => !image.complete)) return null;
                    const cellStyle = getComputedStyle(cell);
                    const cellWidth = cell.getBoundingClientRect().width
                        - parseFloat(cellStyle.paddingLeft) - parseFloat(cellStyle.paddingRight)
                        - parseFloat(cellStyle.borderLeftWidth) - parseFloat(cellStyle.borderRightWidth);
                    const first = images[0].getBoundingClientRect(), second = images[1].getBoundingClientRect();
                    return {cellWidth, firstWidth: first.width, secondWidth: second.width,
                        firstBottom: first.bottom, secondTop: second.top};
                })()
                """, in: nil, contentWorld: .defaultClient) as? [String: Double]
            return geometry != nil
        }
        let metrics = try #require(geometry)
        let cellWidth = try #require(metrics["cellWidth"])
        let firstWidth = try #require(metrics["firstWidth"]), secondWidth = try #require(metrics["secondWidth"])
        let firstBottom = try #require(metrics["firstBottom"]), secondTop = try #require(metrics["secondTop"])
        #expect(cellWidth > 300)
        #expect(abs(firstWidth - cellWidth) <= 1)
        #expect(abs(secondWidth - cellWidth) <= 1)
        #expect(secondTop >= firstBottom - 1,
            "Blocked images styled as blocks must remain vertically stacked")
    }

    @Test(arguments: [false, true])
    func headerDoubleClickChangesExpansionOnceAndControlsKeepTheirOwnActions(initiallyExpanded: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.settings.removePersistentDomain(forName: fixture.suite) }
        let message = try #require(fixture.detail.messages.last)
        let state = HeaderState(expanded: initiallyExpanded)
        let window = makeWindow(HeaderHarness(message: message, mailbox: fixture.mailbox, state: state)
            .environment(fixture.app).defaultAppStorage(fixture.settings), width: 760, height: 280)
        defer { window.close() }
        let clickPoint = try await waitForHeaderPoint(in: window)
        try click(at: clickPoint, in: window, count: 1)
        // SwiftUI must process the first click before the second. Otherwise a
        // test can miss expansion being read again midway through the gesture.
        try await Task.sleep(for: .milliseconds(50))
        try click(at: clickPoint, in: window, count: 2)
        try await eventually { state.transitions == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.transitions == 1)
        #expect(state.expanded == !initiallyExpanded)

        let disclosureID = "message-disclosure-\(message.id)"
        let disclosure = try #require(element(id: disclosureID, in: window))
        try #require(disclosure.press(), "Disclosure must work as an accessible native button")
        try await eventually { state.transitions == 2 }
        #expect(state.expanded == initiallyExpanded)
        if !state.expanded {
            let button = try #require(element(id: disclosureID, in: window))
            try #require(button.press())
            try await eventually { state.expanded }
        }
        let transitionsBeforeDetails = state.transitions
        try await focus(window)
        let details = try #require(element(id: "message-details-\(message.id)", in: window))
        try assertControlHitIsNotHeader(details, in: window)
        try #require(details.press())
        try await eventually {
            NSApp.windows.contains { $0.isVisible && element(id: "message-details-content-\(message.id)", in: $0) != nil }
        }
        #expect(state.expanded)
        #expect(state.transitions == transitionsBeforeDetails, "Opening recipient details must not toggle the header")
        #expect(element(id: "message-details-\(message.id)", in: window)?.value == "Expanded")
        try await closePopover(in: window)
        #expect(element(id: "message-details-\(message.id)", in: window)?.value == "Collapsed")
        #expect(state.transitions == transitionsBeforeDetails)

        try await focus(window)
        let profile = try #require(element(id: "sender-profile-\(message.id)", in: window))
        try assertControlHitIsNotHeader(profile, in: window)
        try #require(profile.press())
        try await eventually {
            NSApp.windows.contains { $0.isVisible && element(id: "sender-view-analytics", in: $0) != nil }
        }
        #expect(state.expanded)
        #expect(state.transitions == transitionsBeforeDetails, "Opening the sender card must not toggle the header")
        try await closePopover(in: window)

        for id in ["message-star-\(message.id)", "message-reply-\(message.id)"] {
            try assertControlHitIsNotHeader(try #require(element(id: id, in: window)), in: window)
        }
        let sender = try #require(element(id: "message-sender-\(message.id)", in: window))
        try assertControlHitIsNotHeader(sender, in: window)
        let senderItems = try await menuTitles(open: { try clickControl(sender, in: window) })
        #expect(senderItems.contains("Copy Address"))
        #expect(senderItems.contains("Search Messages From"))
        #expect(state.transitions == transitionsBeforeDetails)

        let more = try #require(element(id: "message-more-\(message.id)", in: window))
        try assertControlHitIsNotHeader(more, in: window)
        let items = try await menuTitles(open: { try clickControl(more, in: window) })
        #expect(items.contains("Mark Unread from Here"))
        #expect(items.contains("Forward as Attachment"))
        #expect(items.contains("Print Message…"))
        #expect(items.contains("Show Original"))
        let contextItems = try await menuTitles(open: {
            try rightClick(at: try backgroundPoint(in: window), in: window)
        })
        #expect(Set(contextItems) == Set(items), "The header context menu and More must expose the same message commands")
        #expect(state.transitions == transitionsBeforeDetails)
        #expect(state.unreadActions == 0)
        #expect(state.composeActions == 0)

        // A single click leaves an already expanded bar open.
        try click(at: try backgroundPoint(in: window), in: window, count: 1)
        try await settle()
        #expect(state.expanded)
        #expect(state.transitions == transitionsBeforeDetails)
        let body = try #require(element(id: "message-test-body", in: window))
        try assertControlHitIsNotHeader(body, in: window)
        let bodyPoint = window.convertPoint(fromScreen: NSPoint(x: body.frame.midX, y: body.frame.midY))
        try click(at: bodyPoint, in: window, count: 1)
        try click(at: bodyPoint, in: window, count: 2)
        try await settle()
        #expect(state.expanded)
        #expect(state.transitions == transitionsBeforeDetails, "Body text selection must not toggle message expansion")
        window.close()
        await fixture.app.signOut()
    }

    @Test func readerKeepsInitialExpansionAndRendersLightDarkAndNarrowLayouts() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.settings.removePersistentDomain(forName: fixture.suite) }
        let window = makeWindow(ThreadView(key: fixture.key, mailbox: fixture.mailbox)
            .environment(fixture.app).defaultAppStorage(fixture.settings), width: 900, height: 760)
        defer { window.close() }
        let first = try #require(fixture.detail.messages.first)
        let latest = try #require(fixture.detail.messages.last)
        try await eventually { self.element(id: "message-disclosure-\(latest.id)", in: window) != nil }
        #expect(element(id: "message-disclosure-\(first.id)", in: window)?.value == "Collapsed")
        #expect(element(id: "message-disclosure-\(latest.id)", in: window)?.value == "Expanded")
        try await eventually {
            guard let content = window.contentView else { return false }
            return self.descendants(content).compactMap { $0 as? ContentSizedWebView }
                .contains { !$0.isLoading && $0.bounds.height > 40 }
        }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try await focus(window)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 900, height: 760))
            try await settle()
            try capture(window, name: "reader-\(name)-wide.png")
            window.setContentSize(NSSize(width: 420, height: 760))
            try await settle()
            try capture(window, name: "reader-\(name)-narrow.png")
            let more = try #require(element(id: "message-more-\(latest.id)", in: window))
            let content = try #require(window.contentView)
            let frame = content.convert(window.convertFromScreen(more.frame), from: nil)
            #expect(frame.minX >= content.bounds.minX && frame.maxX <= content.bounds.maxX,
                "The message menu must remain inside a narrow reader")
            let details = try #require(element(id: "message-details-\(latest.id)", in: window))
            try #require(details.press())
            try await eventually {
                NSApp.windows.contains { $0.isVisible && element(id: "message-details-content-\(latest.id)", in: $0) != nil }
            }
            try await settle()
            let detailsWindow = try #require(NSApp.windows.first {
                $0.isVisible && element(id: "message-details-content-\(latest.id)", in: $0) != nil
            })
            let expandedDetails = try #require(element(id: "message-details-content-\(latest.id)", in: detailsWindow))
            #expect(expandedDetails.frame.width <= Tokens.Popover.width,
                "Message details must wrap within the popover")
            try capture(detailsWindow, name: "reader-\(name)-details.png")
            try await closePopover(in: window)
        }
        window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        try await settle()
        try capture(window, name: "reader-dark-increased-contrast.png")
        let disclosure = try #require(element(id: "message-disclosure-\(latest.id)", in: window))
        try #require(disclosure.press())
        try await eventually { self.element(id: "message-disclosure-\(latest.id)", in: window)?.value == "Collapsed" }
        try key("\u{F703}", code: 124, in: window)
        try await eventually { self.element(id: "message-disclosure-\(latest.id)", in: window)?.value == "Expanded" }
        try key("\u{F702}", code: 123, in: window)
        try await eventually { self.element(id: "message-disclosure-\(latest.id)", in: window)?.value == "Collapsed" }
        try capture(window, name: "reader-collapsed-keyboard.png")
        let newsletterDisclosure = try #require(element(id: "message-disclosure-\(first.id)", in: window))
        try #require(newsletterDisclosure.press())
        var newsletter: ContentSizedWebView?
        try await eventuallyAsync {
            guard let content = window.contentView else { return false }
            for view in self.descendants(content).compactMap({ $0 as? ContentSizedWebView }) where !view.isLoading {
                let hasPlaceholders = try? await view.evaluateJavaScript("document.querySelector('[data-tern-image-state]') !== null", in: nil, contentWorld: .defaultClient) as? Bool
                if hasPlaceholders == true { newsletter = view; return true }
            }
            return false
        }
        let newsletterView = try #require(newsletter)
        let states = try await newsletterView.evaluateJavaScript("Array.from(document.querySelectorAll('[data-tern-image-state]')).map(image => image.getAttribute('data-tern-image-state'))", in: nil, contentWorld: .defaultClient) as? [String]
        #expect(states?.sorted() == ["blocked", "unavailable"])
        let trackerPresent = try await newsletterView.evaluateJavaScript("document.getElementById('newsletter-tracker') !== null", in: nil, contentWorld: .defaultClient) as? Bool
        #expect(trackerPresent == false)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 560, height: 760))
            try await settle()
            try capture(window, name: "reader-newsletter-\(name).png")
        }
        window.close()
        await fixture.app.signOut()
    }

    @Test func summarySourcesRemainAvailableAndDetailsFollowActualContent() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.settings.removePersistentDomain(forName: fixture.suite) }
        for variant in ["short", "long", "tasks", "decisions"] {
            let report = try summary(for: fixture.detail, variant: variant)
            let state = HeaderState(expanded: false)
            let root = VStack {
                ThreadSummaryContent(report: report, detail: fixture.detail,
                    onOpenSource: { _ in state.sourceActions += 1 }, onRefresh: {}, onSettings: {})
                Spacer(minLength: 0)
            }.padding(Tokens.Space.s4).background(Tokens.Surface.canvas)
            let window = makeWindow(root, width: variant == "long" ? 420 : 760, height: variant == "tasks" ? 480 : 300)
            defer { window.close() }
            func activate(_ id: String) throws {
                let control = try #require(element(id: id, in: window))
                try #require(control.press())
            }
            try await eventually { self.element(id: "summary-disclosure", in: window)?.value == "Expanded" }
            try await settle()
            #expect(element(id: "summary-task-sources-0", in: window) == nil)
            #expect(element(id: "summary-decision-sources-0", in: window) == nil)
            if variant == "long" {
                try await eventually { self.element(id: "summary-details", in: window) != nil }
                try activate("summary-details")
                try await eventually { self.element(id: "summary-details", in: window)?.value == "Expanded" }
                try activate("summary-details")
                try await eventually { self.element(id: "summary-details", in: window)?.value == "Collapsed" }
            } else {
                #expect(element(id: "summary-details", in: window) == nil,
                    "A complete overview must not offer an empty Read more control")
            }
            if variant == "tasks" {
                #expect(element(id: "summary-tasks-toggle", in: window)?.value == "Collapsed")
                #expect(element(id: "summary-decisions-toggle", in: window)?.value == "Collapsed")
            } else if variant == "decisions" {
                #expect(element(id: "summary-tasks-toggle", in: window) == nil)
                #expect(element(id: "summary-decisions-toggle", in: window)?.value == "Collapsed")
            }
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance)
                try await settle()
                try capture(window, name: "summary-\(variant)-compact-\(name).png")
            }
            let sources = try #require(element(id: "summary-sources", in: window))
            _ = try await menuTitles(open: { try clickControl(sources, in: window) }, selectingFirst: true)
            #expect(state.sourceActions == 1)
            #expect(element(id: "summary-disclosure", in: window)?.value == "Expanded")

            // Each section opens independently; the main disclosure restores that choice.
            if variant == "tasks" {
                try activate("summary-tasks-toggle")
                try await eventually { self.element(id: "summary-task-sources-0", in: window) != nil }
                #expect(element(id: "summary-decisions-toggle", in: window)?.value == "Collapsed")
                #expect(element(id: "summary-decision-sources-0", in: window) == nil)
                try await Task.sleep(for: .seconds(Tokens.Motion.base))
                try await settle()
                try capture(window, name: "summary-tasks-only.png")
            }
            try activate("summary-disclosure")
            try await eventually { self.element(id: "summary-overview", in: window) == nil }
            try await eventually { self.element(id: "summary-tasks-toggle", in: window) == nil }
            #expect(element(id: "summary-disclosure", in: window)?.value == "Collapsed")
            if variant == "tasks" {
                #expect(elements(in: window).contains { $0.label == "Based on partial message content" })
                window.setContentSize(NSSize(width: 420, height: 480))
            }
            try await Task.sleep(for: .seconds(Tokens.Motion.base))
            try await settle()
            try capture(window, name: "summary-\(variant)-minimised.png")
            let minimisedSources = try #require(element(id: "summary-sources", in: window))
            _ = try await menuTitles(open: { try clickControl(minimisedSources, in: window) }, selectingFirst: true)
            #expect(state.sourceActions == 2)
            #expect(element(id: "summary-disclosure", in: window)?.value == "Collapsed",
                "Opening a source must not expand the summary")
            try activate("summary-disclosure")
            try await eventually { self.element(id: "summary-overview", in: window) != nil }
            if variant == "tasks" {
                #expect(element(id: "summary-tasks-toggle", in: window)?.value == "Expanded")
                #expect(element(id: "summary-decisions-toggle", in: window)?.value == "Collapsed")
                try activate("summary-tasks-toggle")
                try await eventually { self.element(id: "summary-task-sources-0", in: window) == nil }
                try activate("summary-decisions-toggle")
                try await eventually { self.element(id: "summary-decision-sources-0", in: window) != nil }
                #expect(element(id: "summary-tasks-toggle", in: window)?.value == "Collapsed")
            }

            if variant != "short" {
                // Expand All must also open the shell from its minimised state.
                try activate("summary-disclosure")
                try await eventually { self.element(id: "summary-disclosure", in: window)?.value == "Collapsed" }
                try activate("summary-expand-all")
                try await eventually { self.element(id: "summary-disclosure", in: window)?.value == "Expanded" }
                if variant == "long" {
                    try await eventually { self.element(id: "summary-details", in: window)?.value == "Expanded" }
                } else {
                    try await eventually { self.element(id: "summary-decisions-toggle", in: window)?.value == "Expanded" }
                    if variant == "tasks" {
                        #expect(element(id: "summary-tasks-toggle", in: window)?.value == "Expanded")
                    }
                }
                try await Task.sleep(for: .seconds(Tokens.Motion.base))
                for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    window.appearance = NSAppearance(named: appearance)
                    if variant == "tasks" { window.setContentSize(NSSize(width: 760, height: 480)) }
                    try await settle()
                    try capture(window, name: "summary-\(variant)-expanded-\(name).png")
                    if variant == "tasks" {
                        window.setContentSize(NSSize(width: 420, height: 600))
                        try await settle()
                        try capture(window, name: "summary-tasks-narrow-\(name).png")
                        let lastTaskSource = try #require(element(id: "summary-task-sources-2", in: window))
                        let content = try #require(window.contentView)
                        let frame = content.convert(window.convertFromScreen(lastTaskSource.frame), from: nil)
                        #expect(content.bounds.contains(frame), "Task sources must remain reachable after metadata wraps")
                    }
                }
                if variant == "tasks" {
                    let taskSource = try #require(element(id: "summary-task-sources-1", in: window))
                    _ = try await menuTitles(open: { try clickControl(taskSource, in: window) }, selectingFirst: true)
                    let decisionSource = try #require(element(id: "summary-decision-sources-0", in: window))
                    _ = try await menuTitles(open: { try clickControl(decisionSource, in: window) }, selectingFirst: true)
                    #expect(state.sourceActions == 4)
                    #expect(element(id: "summary-tasks-toggle", in: window)?.value == "Expanded")
                    #expect(element(id: "summary-decisions-toggle", in: window)?.value == "Expanded")
                }
                try activate("summary-expand-all")
                try await eventually { self.element(id: "summary-task-sources-0", in: window) == nil }
                try await eventually { self.element(id: "summary-decision-sources-0", in: window) == nil }
                if variant == "long" {
                    #expect(element(id: "summary-details", in: window)?.value == "Collapsed")
                }
                #expect(element(id: "summary-disclosure", in: window)?.value == "Expanded",
                    "Collapse All keeps the summary overview visible")
                // Mixed-state Expand All opens only what is closed, without hiding open content.
                if variant == "tasks" {
                    try activate("summary-tasks-toggle")
                    try await eventually { self.element(id: "summary-tasks-toggle", in: window)?.value == "Expanded" }
                    try activate("summary-expand-all")
                    try await eventually { self.element(id: "summary-decisions-toggle", in: window)?.value == "Expanded" }
                    #expect(element(id: "summary-tasks-toggle", in: window)?.value == "Expanded")
                }
            } else {
                #expect(element(id: "summary-expand-all", in: window) == nil)
            }
            window.close()
        }
        await fixture.app.signOut()
    }

    private func summary(for detail: ThreadDetail, variant: String) throws -> ThreadSummaryReport {
        let message = try #require(detail.messages.last)
        let source = AssistantSource(accountID: message.record.accountID, threadID: message.record.threadID,
            messageID: message.id, partID: nil, title: "Field visit")
        let text = variant == "long"
            ? String(repeating: "The revised route is ready for review. The team needs comments before confirming the equipment list. ", count: 5)
            : "The revised route is ready. Alexandra needs feedback on the equipment list."
        let tasks: [[String: Any]] = variant == "tasks" ? [
            ["description": "Review the equipment list and flag any items that need replacing before the field visit.",
             "owner": "Alexandra Morgan", "due_date": "2026-11-04", "source_ids": [source.id]],
            ["description": "Confirm the transport arrangements for the research team.",
             "owner": "Sam Patel and the field operations coordination team", "due_date": "2026-11-06", "source_ids": [source.id]],
            ["description": "Share the final route with everyone joining the visit.",
             "owner": NSNull(), "due_date": NSNull(), "source_ids": [source.id]],
        ] : []
        let decisions: [[String: Any]] = variant == "tasks" ? [
            ["text": "Use the revised north entrance route for the visit.", "source_ids": [source.id]],
            ["text": "Keep the existing equipment budget; confirm any replacements before placing an order.", "source_ids": [source.id]],
        ] : variant == "decisions" ? [
            ["text": "Use the revised north entrance route for the visit.", "source_ids": [source.id]],
        ] : []
        let data = try JSONSerialization.data(withJSONObject: ["summary": text, "source_ids": [source.id],
            "decisions": decisions, "open_tasks": tasks])
        return ThreadSummaryReport(summary: try AssistantSummary.decode(data, allowedSourceIDs: [source.id]),
            sources: [source], hasPartialCoverage: variant == "tasks")
    }

    private func makeWindow(_ root: some View, width: CGFloat, height: CGFloat) -> NSWindow {
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.appearance = NSAppearance(named: .aqua)
        window.level = .floating
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func waitForHeaderPoint(in window: NSWindow) async throws -> NSPoint {
        var point: NSPoint?
        do {
            try await eventually {
                window.contentView?.layoutSubtreeIfNeeded()
                point = try? self.backgroundPoint(in: window)
                return point != nil
            }
        } catch {
            try capture(window, name: "header-hit-routing-failure.png")
            for view in clickViews(in: window) {
                let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let hit = routedHit(at: center, in: window)
                print("Header routing: frame=\(view.frame), bounds=\(view.bounds), controlRects=\(view.controlRects), hit=\(hit.map { String(describing: type(of: $0)) } ?? "none")")
            }
            print("Header content frame=\(window.contentView?.frame ?? .zero), superview=\(window.contentView?.superview?.frame ?? .zero)")
            throw error
        }
        return try #require(point)
    }

    private func backgroundPoint(in window: NSWindow) throws -> NSPoint {
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        for clickView in clickViews(in: window) where clickView.bounds.width > 0 && clickView.bounds.height > 0 {
            for y in stride(from: 4.0, to: clickView.bounds.height, by: 8.0) {
                for x in stride(from: 4.0, to: clickView.bounds.width, by: 8.0) {
                    let point = clickView.convert(NSPoint(x: x, y: y), to: nil)
                    if routedHit(at: point, in: window) === clickView { return point }
                }
            }
        }
        throw TestFailure.noHeaderHitTarget
    }

    /// NSView.hitTest accepts a point in its parent's coordinates. Start at
    /// the same frame view AppKit uses, including the content view's offset.
    private func routedHit(at windowPoint: NSPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let root = content.superview ?? content
        let point = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
        return root.hitTest(point)
    }

    private func clickControl(_ element: AXElement, in window: NSWindow) throws {
        try #require(!element.frame.isEmpty, "The native menu must have a visible target")
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        try #require(routedHit(at: point, in: window) != nil)
        try click(at: point, in: window, count: 1)
    }

    private func click(at point: NSPoint, in window: NSWindow, count: Int) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func key(_ characters: String, code: UInt16, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func rightClick(at point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func assertControlHitIsNotHeader(_ element: AXElement, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        let hit = routedHit(at: point, in: window)
        #expect(hit != nil)
        #expect(!(hit is MessageHeaderClickView), "A control must receive its own clicks above the header surface")
    }

    private func focus(_ window: NSWindow) async throws {
        // Native popup presentation and Escape handling require real focus,
        // even when accessibility actions are invoked directly by the test.
        if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps]) }
        window.makeKeyAndOrderFront(nil)
        try await eventually {
            NSApp.isActive && window.isKeyWindow
        }
    }

    private func closePopover(in window: NSWindow) async throws {
        if let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.className.contains("Popover") }) {
            try await focus(popover)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popover.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.sendEvent(event)
            try await eventually { !popover.isVisible }
        }
        try await focus(window)
        try await settle()
    }

    private func menuTitles(open: () throws -> Void, selectingFirst: Bool = false) async throws -> [String] {
        let attempt = MenuAttempt()
        NotificationCenter.default.addObserver(attempt, selector: #selector(MenuAttempt.began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(attempt) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let menu = attempt.menu {
                    attempt.titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                    if selectingFirst, let index = menu.items.firstIndex(where: { !$0.isSeparatorItem && $0.isEnabled }) {
                        menu.performActionForItem(at: index)
                    }
                    menu.cancelTrackingWithoutAnimation()
                    attempt.completed = true
                    attempt.timer?.invalidate()
                } else if ContinuousClock.now >= deadline {
                    attempt.completed = true
                    attempt.timer?.invalidate()
                    if let window = NSApp.keyWindow,
                       let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(escape, atStart: true)
                    }
                }
            }
        }
        attempt.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        try open()
        try await eventually { attempt.completed }
        try #require(attempt.menu != nil, "The native menu must enter tracking")
        return attempt.titles
    }

    private func clickViews(in window: NSWindow) -> [MessageHeaderClickView] {
        window.contentView.map { descendants($0).compactMap { $0 as? MessageHeaderClickView } } ?? []
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func element(id: String, in window: NSWindow) -> AXElement? { elements(in: window).first { $0.id == id } }
    private func elements(in window: NSWindow) -> [AXElement] {
        var seen: Set<ObjectIdentifier> = []
        func visit(_ item: Any) -> [AXElement] {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = AXElement(object: object)
            return [element] + (element.children + NSAccessibility.unignoredChildren(from: element.children)).flatMap(visit)
        }
        return ([window] + (window.contentView.map(descendants) ?? [])).flatMap(visit)
    }
    private func capture(_ window: NSWindow, name: String) throws {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name)
    }
    private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await settle() }
        try #require(condition(), "The hosted reader must reach its expected state", sourceLocation: sourceLocation)
    }
    private func eventuallyAsync(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !condition() {
            try #require(ContinuousClock.now < deadline, "The newsletter body must finish rendering")
            try await settle()
        }
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
    private enum TestFailure: Error { case noHeaderHitTarget }

    @MainActor private final class MenuAttempt: NSObject {
        var menu: NSMenu?
        var titles: [String] = []
        var completed = false
        var timer: Timer?
        @objc func began(_ notification: Notification) { menu = notification.object as? NSMenu }
    }

    @MainActor private struct AXElement {
        let object: NSObject
        private func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var children: [Any] { value("accessibilityChildren") as? [Any] ?? object.accessibilityAttributeValue(.children) as? [Any] ?? [] }
        var id: String? { value("accessibilityIdentifier") as? String ?? object.accessibilityAttributeValue(.identifier) as? String }
        var label: String? { value("accessibilityLabel") as? String ?? object.accessibilityAttributeValue(.description) as? String ?? object.accessibilityAttributeValue(.title) as? String }
        var value: String? { value("accessibilityValue") as? String ?? object.accessibilityAttributeValue(.value) as? String }
        var role: String? { value("accessibilityRole") as? String ?? object.accessibilityAttributeValue(.role) as? String }
        var frame: NSRect {
            if let rect = value("accessibilityFrame") as? NSValue { return rect.rectValue }
            guard let point = object.accessibilityAttributeValue(.position) as? NSValue,
                  let size = object.accessibilityAttributeValue(.size) as? NSValue else { return .zero }
            return NSRect(origin: point.pointValue, size: size.sizeValue)
        }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if object.responds(to: selector), let implementation = object.method(for: selector) {
                // Public AppKit accessibility selector: -(BOOL)accessibilityPerformPress.
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                return unsafeBitCast(implementation, to: Press.self)(object, selector)
            }
            guard object.accessibilityActionNames().contains(.press) else { return false }
            object.accessibilityPerformAction(.press)
            return true
        }
    }

    @MainActor private struct Fixture {
        let app: AppModel
        let mailbox: MailboxModel
        let key: ThreadKey
        let detail: ThreadDetail
        let suite: String
        let settings: UserDefaults

        static func make() async throws -> Self {
            try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "Reader interaction tests must use synthetic accounts")
            let app = AppModel()
            await app.start()
            let mailbox = try #require(app.mailbox), cache = try #require(app.cache)
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !mailbox.hasSyncedOnce, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try #require(mailbox.hasSyncedOnce)
            let key = ThreadKey(accountID: "ui-audit", threadID: "reader-design-\(UUID().uuidString)")
            let date = Date(timeIntervalSince1970: 1_793_606_400)
            try await cache.write { tx in
                for index in 0..<2 {
                    let id = key.threadID + "-\(index)"
                    let record = MessageRecord(accountID: key.accountID, id: id, threadID: key.threadID, historyID: 1,
                        date: date.addingTimeInterval(Double(index * 3_600)), snippet: index == 0 ? "The first route proposal is attached." : "View this email in your browser. Please review the revised equipment list.",
                        sender: index == 0 ? "Rowan Ellis <rowan@example.invalid>" : "Alexandra Morgan and the field research team <team@example.invalid>",
                        recipients: "UI Audit <audit@example.invalid>, Sam Patel <sam@example.invalid>",
                        cc: "Mira Chen <mira@example.invalid>, Casey <casey@example.invalid>",
                        subject: "Field visit and equipment checklist", sizeEstimate: 4_096)
                    _ = try tx.upsertMessages([.init(record: record, labelIDs: index == 0 ? [SystemLabel.inbox] : [SystemLabel.inbox, SystemLabel.unread, SystemLabel.starred])])
                    let html = index == 0 ? """
                        <table style="width:100%;max-width:600px;background:#fff;color:#242424"><tr><td>
                        <p style="font-size:24px">Field research newsletter</p>
                        <p>The first route proposal is ready for review.</p>
                        <img src="https://images.example.invalid/route.jpg" width="600" height="240" alt="Proposed field route">
                        <p>Route key</p><img src="cid:missing-route-key" width="100" height="80">
                        <img id="newsletter-tracker" src="https://images.example.invalid/open.gif" width="1" height="1">
                        <p>Please send comments on the equipment list.</p>
                        </td></tr></table>
                        """ : "<p>Hello everyone,</p><p>The revised route is ready. Please review the equipment list and send your comments.</p><p>We will confirm the route after reviewing the comments.</p><p>Thanks,<br>Alexandra</p>"
                    try tx.saveBodies([.init(accountID: key.accountID, messageID: id, html: html, plainText: nil, fetchedAt: date)])
                    try tx.setBodyEnrichedAt(date, messageID: id, accountID: key.accountID)
                    if index == 1 {
                        try tx.replaceAttachments([.init(accountID: key.accountID, messageID: id, partID: "1", attachmentID: "synthetic",
                            filename: "Field visit equipment checklist.pdf", mimeType: "application/pdf", size: 24_576, isInline: false)],
                            messageID: id, accountID: key.accountID)
                    }
                }
                try tx.rebuildThreads([key.threadID], accountID: key.accountID)
            }
            var iterator = cache.thread(accountID: key.accountID, threadID: key.threadID).makeAsyncIterator()
            let snapshot = try await iterator.next()
            let detail = try #require(snapshot ?? nil)
            let suite = "MessageHeaderInteractionTests.\(UUID().uuidString)"
            let settings = try #require(UserDefaults(suiteName: suite))
            settings.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
            settings.set(true, forKey: ReadingPreferences.blockImagesKey)
            settings.set(true, forKey: ReadingPreferences.adaptDarkKey)
            return Self(app: app, mailbox: mailbox, key: key, detail: detail, suite: suite, settings: settings)
        }
    }
}

@MainActor @Observable private final class HeaderState {
    var expanded: Bool
    var transitions = 0
    var unreadActions = 0
    var composeActions = 0
    var sourceActions = 0
    init(expanded: Bool) { self.expanded = expanded }
}

@MainActor private final class ImageLayoutState {
    var height: CGFloat = 0
}

private struct HeaderHarness: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let state: HeaderState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MessageHeader(message: message, mailbox: mailbox, isExpanded: state.expanded,
                compose: { _ in state.composeActions += 1 }, onMarkUnreadFromHere: { state.unreadActions += 1 },
                onToggle: { state.expanded.toggle(); state.transitions += 1 }) { EmptyView() }
            if state.expanded {
                Divider()
                Text("Synthetic message body. Double-clicking body text selects text.")
                    .textSelection(.enabled).padding(Tokens.Space.s4)
                    .accessibilityIdentifier("message-test-body")
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s4)
        .background(Tokens.Surface.canvas)
    }
}
