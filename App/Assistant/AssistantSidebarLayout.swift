import AppKit
import SwiftUI

/// Allocate the assistant inside the existing window. At narrow widths the
/// mailbox navigation closes temporarily, leaving the list and reader usable.
struct AssistantSidebarLayout {
    static let navigationMinimum = Tokens.Layout.sidebarMinWidth + Tokens.Space.s3
    static let listMinimum = Tokens.Layout.listMinWidth + Tokens.Space.s3
    static let threeColumnMinimum = navigationMinimum + listMinimum + Tokens.Assistant.readerMinWidth + 2 * Tokens.Border.hairline

    let sidebarWidth: CGFloat
    let mailWidth: CGFloat
    let hidesMailboxNavigation: Bool

    init(availableWidth: CGFloat, preferredWidth: CGFloat, isPresented: Bool) {
        let width = max(0, availableWidth)
        guard isPresented else {
            sidebarWidth = 0; mailWidth = width; hidesMailboxNavigation = false
            return
        }
        let available = width - Self.threeColumnMinimum - Tokens.Border.hairline
        hidesMailboxNavigation = available < Tokens.Assistant.sidebarMinWidth
        if hidesMailboxNavigation {
            sidebarWidth = min(Tokens.Assistant.sidebarMinWidth, width)
        } else {
            sidebarWidth = min(max(preferredWidth, Tokens.Assistant.sidebarMinWidth), Tokens.Assistant.sidebarMaxWidth, available)
        }
        mailWidth = max(0, width - sidebarWidth - Tokens.Border.hairline)
    }
}

/// Keeps the native split controller and its constraints in charge. Probes find
/// only their own ancestors, so a detached assistant never affects another window.
@MainActor
final class AssistantMailPaneSizing {
    enum Pane: CaseIterable { case navigation, list }
    private struct Divider {
        weak var split: NSSplitView?
        weak var pane: NSView?
        let index: Int
    }
    private enum Mode: Equatable { case normal, compressed, restoring }
    private var dividers: [Pane: Divider] = [:]
    private var originalWidths: [Pane: CGFloat] = [:]
    private var mode = Mode.normal
    private var remainingAttempts = 0
    private var scheduled = false

    func beginPresentation() {
        guard mode != .compressed else { return }
        if mode == .normal {
            originalWidths = dividers.compactMapValues { divider in
                guard let split = divider.split, let pane = divider.pane, !split.isSubviewCollapsed(pane) else { return nil }
                return pane.frame.width
            }
        }
        mode = .compressed
        requestApply()
    }

    func endPresentation() {
        guard mode != .normal else { return }
        mode = .restoring
        requestApply()
    }

    func attach(_ view: NSView, pane role: Pane) {
        var child = view
        while let parent = child.superview {
            if let split = parent as? NSSplitView, split.isVertical,
               let index = split.arrangedSubviews.firstIndex(where: { $0 === child }),
               index < split.arrangedSubviews.count - 1 {
                let old = dividers[role]
                dividers[role] = Divider(split: split, pane: child, index: index)
                if old?.split !== split || old?.pane !== child { requestApply() }
                return
            }
            child = parent
        }
    }

    /// SwiftUI can apply column constraints after updating the representable.
    /// Retry only while layout is settling, with a fixed budget and no animation.
    func requestApply() {
        guard mode != .normal else { return }
        remainingAttempts = 3
        schedulePendingApply()
    }

    func schedulePendingApply() {
        guard !scheduled, remainingAttempts > 0 else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            scheduled = false
            apply()
        }
    }

    func apply() {
        guard mode != .normal, remainingAttempts > 0 else { return }
        remainingAttempts -= 1
        var settled = true
        for role in Pane.allCases {
            guard let divider = dividers[role], let split = divider.split, let pane = divider.pane,
                  divider.index < split.arrangedSubviews.count - 1,
                  split.arrangedSubviews[divider.index] === pane,
                  !split.isSubviewCollapsed(pane) else {
                if mode == .restoring, originalWidths[role] != nil { settled = false }
                continue
            }
            let target: CGFloat
            if mode == .compressed {
                target = role == .navigation ? AssistantSidebarLayout.navigationMinimum : AssistantSidebarLayout.listMinimum
            } else {
                guard let width = originalWidths[role] else { continue }
                target = width
            }
            let lower = split.minPossiblePositionOfDivider(at: divider.index)
            let upper = split.maxPossiblePositionOfDivider(at: divider.index)
            let position = min(max(pane.frame.minX + target, lower), upper)
            if abs(pane.frame.width - target) > 0.5 { split.setPosition(position, ofDividerAt: divider.index) }
            settled = settled && abs(pane.frame.width - target) <= 0.5
        }
        if settled {
            remainingAttempts = 0
            if mode == .restoring { mode = .normal; originalWidths = [:] }
        }
    }
}

struct AssistantMailPaneProbe: NSViewRepresentable {
    let sizing: AssistantMailPaneSizing
    let pane: AssistantMailPaneSizing.Pane
    let isPresented: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.sizing = sizing; view.pane = pane
        sizing.attach(view, pane: pane)
        if view.isPresented != isPresented {
            view.isPresented = isPresented
            sizing.requestApply()
        }
    }

    final class ProbeView: NSView {
        weak var sizing: AssistantMailPaneSizing?
        var pane = AssistantMailPaneSizing.Pane.navigation
        var isPresented = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sizing?.attach(self, pane: pane)
        }
        override func layout() {
            super.layout()
            sizing?.attach(self, pane: pane)
            sizing?.schedulePendingApply()
        }
    }
}

struct AssistantSidebarResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) { view.width = width; view.onResize = onResize }

    final class ResizeView: NSView {
        var width: CGFloat = 0
        var onResize: ((CGFloat) -> Void)?
        private var startX: CGFloat = 0
        private var startWidth: CGFloat = 0
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x; startWidth = width }
        override func mouseDragged(with event: NSEvent) { onResize?(startWidth + startX - event.locationInWindow.x) }
    }
}
