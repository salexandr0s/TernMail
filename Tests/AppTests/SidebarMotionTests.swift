import AppKit
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct SidebarMotionTests {
    @Test
    func reversingPresentationPreservesNativeDetailAndDraggedWidth() async throws {
        let fixture = Fixture(isPresented: true)
        defer { fixture.close() }
        try await fixture.settle()
        let split = try fixture.split()
        try #require(split.arrangedSubviews.count == 2)
        let detail = try fixture.marker(.detail)
        let draggedWidth = Tokens.Layout.sidebarMaxWidth - Tokens.Space.s4
        split.setPosition(draggedWidth, ofDividerAt: 0)
        try await fixture.waitUntil { abs(fixture.state.sidebarWidth - draggedWidth) <= 1 }

        fixture.state.isPresented = false
        // Reverse before the normal presentation duration elapses. An older
        // completion must not remove the sidebar after the new open request.
        try await fixture.layoutAfter(.milliseconds(30))
        fixture.state.isPresented = true
        try await fixture.settle()
        #expect(try fixture.split() === split)
        try #require(split.arrangedSubviews.count == 2)
        #expect(try fixture.marker(.detail) === detail)
        #expect(abs(try fixture.marker(.sidebar).frame.width - draggedWidth) <= 1)
        #expect(abs(fixture.state.sidebarWidth - draggedWidth) <= 1)

        fixture.state.isPresented = false
        try await fixture.settle()
        try #require(split.arrangedSubviews.count == 1)
        #expect(try fixture.marker(.detail) === detail)
        let hiddenFrame = detail.convert(detail.bounds, to: fixture.root)
        #expect(abs(hiddenFrame.minX) <= 1)
        #expect(abs(hiddenFrame.width - fixture.root.bounds.width) <= 1)

        fixture.state.isPresented = true
        try await fixture.settle()
        try #require(split.arrangedSubviews.count == 2)
        #expect(try fixture.marker(.detail) === detail)
        #expect(abs(try fixture.marker(.sidebar).frame.width - draggedWidth) <= 1)
        #expect(abs(fixture.state.sidebarWidth - draggedWidth) <= 1)
        print("TERN_SIDEBAR_MOTION reduce=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) reversal-and-width-passed")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--reduce-motion-audit")))
    func reducedMotionStartsAndEndsInTheRequestedNativeLayout() async throws {
        try #require(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                     "This audit uses the existing macOS Reduce Motion preference")
        let fixture = Fixture(isPresented: false)
        defer { fixture.close() }
        try await fixture.settle()
        let split = try fixture.split()
        let detail = try fixture.marker(.detail)
        try #require(split.arrangedSubviews.count == 1)
        for shown in [true, false, true, false] {
            fixture.state.isPresented = shown
            try await fixture.layoutAfter(.milliseconds(30))
            #expect(split.arrangedSubviews.count == (shown ? 2 : 1))
            #expect(try fixture.marker(.detail) === detail)
            let frame = detail.convert(detail.bounds, to: fixture.root)
            if shown {
                #expect(abs(frame.minX - fixture.state.sidebarWidth - split.dividerThickness) <= 1)
            } else {
                #expect(abs(frame.minX) <= 1)
                #expect(abs(frame.width - fixture.root.bounds.width) <= 1)
            }
        }
    }

    @MainActor private final class Fixture {
        let state: SidebarMotionState
        let controller: NSHostingController<SidebarMotionHost>
        let window: NSWindow
        var root: NSView { controller.view }

        init(isPresented: Bool) {
            state = SidebarMotionState(isPresented: isPresented)
            controller = NSHostingController(rootView: SidebarMotionHost(state: state))
            controller.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 1_000, height: 500))
            window.orderBack(nil)
        }

        func close() {
            window.close()
            window.contentViewController = nil
        }

        func split() throws -> NSSplitView {
            try #require(descendants(root).compactMap { $0 as? NSSplitView }.first)
        }

        func marker(_ role: SidebarMotionMarker.Role) throws -> SidebarMotionMarker.NativeView {
            try #require(descendants(root).compactMap { $0 as? SidebarMotionMarker.NativeView }
                .first { $0.role == role })
        }

        func settle() async throws {
            try await layoutAfter(.milliseconds(400))
        }

        func layoutAfter(_ delay: Duration) async throws {
            window.layoutIfNeeded()
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: delay)
            window.layoutIfNeeded()
            root.layoutSubtreeIfNeeded()
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition(), ContinuousClock.now < deadline {
                try await layoutAfter(.milliseconds(20))
            }
            try #require(condition())
        }

        private func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
    }
}

@MainActor private final class SidebarMotionState: ObservableObject {
    @Published var isPresented: Bool
    @Published var sidebarWidth = Tokens.Layout.sidebarWidth

    init(isPresented: Bool) { self.isPresented = isPresented }
}

private struct SidebarMotionHost: View {
    @ObservedObject var state: SidebarMotionState

    var body: some View {
        TernSidebarSplit(isPresented: state.isPresented, sidebarWidth: $state.sidebarWidth,
                         minimumWidth: Tokens.Layout.sidebarMinWidth, maximumWidth: Tokens.Layout.sidebarMaxWidth) {
            SidebarMotionMarker(role: .sidebar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            SidebarMotionMarker(role: .detail)
                .frame(minWidth: Tokens.Layout.emptyStateWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SidebarMotionMarker: NSViewRepresentable {
    enum Role { case sidebar, detail }
    let role: Role

    func makeNSView(context: Context) -> NativeView { NativeView(role: role) }
    func updateNSView(_ view: NativeView, context: Context) {}

    final class NativeView: NSView {
        let role: Role
        init(role: Role) { self.role = role; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
    }
}
