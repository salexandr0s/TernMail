import AppKit
import Testing
@testable import Tern

@Suite @MainActor struct AssistantSidebarLayoutTests {
    @Test(arguments: [CGFloat(960), CGFloat(1280)])
    func openingResizingAndClosingKeepNativePanesInsideTheSameWindow(width: CGFloat) throws {
        let fixture = Fixture(width: width)
        defer { fixture.window.close() }
        fixture.setPaneWidths(navigation: 232, list: 372)
        let originalWindow = fixture.window.frame
        let originalNavigation = fixture.navigation.frame.width
        let originalList = fixture.list.frame.width

        fixture.sizing.beginPresentation()
        let open = AssistantSidebarLayout(availableWidth: width, preferredWidth: 380, isPresented: true)
        fixture.show(open)
        fixture.compressAsColumnWidthsDo()
        // The column widths own compression; the sizing leaves them alone.
        fixture.sizing.requestApply()
        fixture.sizing.apply()

        #expect(fixture.window.frame == originalWindow)
        #expect(abs(fixture.list.frame.width - AssistantSidebarLayout.listMinimum) < 1)
        #expect(fixture.reader.frame.width >= Tokens.Assistant.readerMinWidth - 1)
        #expect(fixture.sidebar.frame.maxX <= fixture.container.bounds.maxX)
        #expect(fixture.split.frame.maxX < fixture.sidebar.frame.minX)
        if width == 960 {
            #expect(fixture.controller.splitViewItems[0].isCollapsed)
            #expect(fixture.sidebar.frame.width == Tokens.Assistant.sidebarMinWidth)
        } else {
            #expect(!fixture.controller.splitViewItems[0].isCollapsed)
            #expect(abs(fixture.navigation.frame.width - AssistantSidebarLayout.navigationMinimum) < 1)
            #expect(fixture.sidebar.frame.width == Tokens.Assistant.sidebarWidth)
            fixture.show(AssistantSidebarLayout(availableWidth: width, preferredWidth: 480, isPresented: true))
            #expect(fixture.reader.frame.width >= Tokens.Assistant.readerMinWidth - 1)
            #expect(fixture.sidebar.frame.width <= Tokens.Assistant.sidebarMaxWidth)
            #expect(fixture.sidebar.frame.maxX <= fixture.container.bounds.maxX)
            #expect(fixture.split.frame.maxX < fixture.sidebar.frame.minX)
        }

        fixture.hide()
        fixture.sizing.endPresentation()
        fixture.sizing.apply()
        #expect(abs(fixture.navigation.frame.width - originalNavigation) < 1)
        #expect(abs(fixture.list.frame.width - originalList) < 1)
        #expect(!fixture.controller.splitViewItems[0].isCollapsed)
        #expect(fixture.window.frame == originalWindow)
        #expect(fixture.split.frame == fixture.container.bounds)
    }

    @Test func restoreWaitsForTheSplitToWiden() {
        let fixture = Fixture(width: 1280)
        defer { fixture.window.close() }
        fixture.setPaneWidths(navigation: 232, list: 372)
        let originalList = fixture.list.frame.width
        fixture.sizing.beginPresentation()
        fixture.show(AssistantSidebarLayout(availableWidth: 1280, preferredWidth: 380, isPresented: true))
        fixture.compressAsColumnWidthsDo()

        // Attempts can run before the split takes back the assistant's width.
        fixture.sizing.endPresentation()
        for _ in 0..<3 { fixture.sizing.apply() }
        fixture.hide()
        fixture.sizing.apply()
        #expect(abs(fixture.list.frame.width - originalList) < 1)
    }

    @Test func delayedColumnUncollapseDoesNotDiscardRestoration() {
        let fixture = Fixture(width: 960)
        defer { fixture.window.close() }
        fixture.setPaneWidths(navigation: 240, list: 360)
        let original = fixture.navigation.frame.width
        fixture.sizing.beginPresentation()
        fixture.show(AssistantSidebarLayout(availableWidth: 960, preferredWidth: 380, isPresented: true))
        fixture.sizing.apply()

        // SwiftUI may update visibility a layout pass after closing the sidebar.
        fixture.sizing.endPresentation()
        fixture.sizing.apply()
        fixture.hide()
        fixture.sizing.requestApply()
        fixture.sizing.apply()
        #expect(abs(fixture.navigation.frame.width - original) < 1)
    }

    @MainActor private final class Fixture {
        let window: NSWindow
        let container: NSView
        let controller = NSSplitViewController()
        let sidebar = NSView()
        let sizing = AssistantMailPaneSizing()
        var split: NSSplitView { controller.splitView }
        var navigation: NSView { split.arrangedSubviews[0] }
        var list: NSView { split.arrangedSubviews[1] }
        var reader: NSView { split.arrangedSubviews[2] }

        init(width: CGFloat) {
            let bounds = NSRect(x: 0, y: 0, width: width, height: 600)
            container = NSView(frame: bounds)
            window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
            controller.splitView.isVertical = true
            controller.splitView.dividerStyle = .thin
            for (index, minimum) in [AssistantSidebarLayout.navigationMinimum, AssistantSidebarLayout.listMinimum, Tokens.Assistant.readerMinWidth].enumerated() {
                let child = NSViewController()
                child.view = NSView()
                let item = NSSplitViewItem(viewController: child)
                item.minimumThickness = minimum
                item.canCollapse = index == 0
                controller.addSplitViewItem(item)
            }
            controller.view.frame = bounds
            container.addSubview(controller.view)
            container.addSubview(sidebar)
            split.adjustSubviews()
            split.layoutSubtreeIfNeeded()
            for (role, pane) in [(AssistantMailPaneSizing.Pane.navigation, navigation), (.list, list)] {
                let probe = NSView(frame: pane.bounds)
                pane.addSubview(probe)
                EnclosingSplitDivider(of: probe).map { sizing.attach($0, as: role) }
            }
        }

        func setPaneWidths(navigation: CGFloat, list: CGFloat) {
            split.setPosition(navigation, ofDividerAt: 0)
            split.setPosition(navigation + split.dividerThickness + list, ofDividerAt: 1)
            split.layoutSubtreeIfNeeded()
        }

        /// MainView sets each column's minimum, ideal and maximum width equal
        /// while the assistant shows; the bare controller needs the positions.
        func compressAsColumnWidthsDo() {
            if controller.splitViewItems[0].isCollapsed {
                split.setPosition(list.frame.minX + AssistantSidebarLayout.listMinimum, ofDividerAt: 1)
            } else {
                setPaneWidths(navigation: AssistantSidebarLayout.navigationMinimum, list: AssistantSidebarLayout.listMinimum)
            }
            split.layoutSubtreeIfNeeded()
        }

        func show(_ layout: AssistantSidebarLayout) {
            controller.splitViewItems[0].isCollapsed = layout.hidesMailboxNavigation
            // NSSplitViewController owns a wrapper view that sizes its split view.
            // Resize that host, as MainView's adjacent SwiftUI layout does.
            controller.view.setFrameSize(NSSize(width: layout.mailWidth, height: container.bounds.height))
            sidebar.frame = NSRect(x: layout.mailWidth + Tokens.Border.hairline, y: 0,
                width: layout.sidebarWidth, height: container.bounds.height)
            controller.view.layoutSubtreeIfNeeded()
        }

        func hide() {
            controller.view.frame = container.bounds
            controller.splitViewItems[0].isCollapsed = false
            sidebar.frame = .zero
            controller.view.layoutSubtreeIfNeeded()
        }
    }
}
