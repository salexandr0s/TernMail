import AppKit
import SwiftUI

/// Allocate the assistant inside the existing window. At narrow widths the
/// mailbox navigation closes temporarily, leaving the list and reader usable.
struct AssistantSidebarLayout {
    /// The `UserDefaults` key for the width the sidebar was last dragged to.
    static let widthKey = "assistantSidebarWidth"
    static let navigationMinimum = Tokens.Layout.sidebarMinWidth + Tokens.Layout.columnGutter
    static let listMinimum = Tokens.Layout.listMinWidth + Tokens.Layout.columnGutter
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

/// Puts the user's divider positions back after the assistant closes. While it
/// shows, the columns' equal minimum, ideal and maximum widths narrow the panes
/// and the native split collapses navigation at narrow widths. After a collapse
/// the split falls back to the list's minimum width, so the dragged widths need
/// restoring. Probes find only their own ancestors, so a detached assistant
/// never affects another window.
@MainActor
final class AssistantMailPaneSizing {
    enum Pane: CaseIterable { case navigation, list }
    private struct SplitDivider {
        weak var split: NSSplitView?
        weak var pane: NSView?
        let index: Int
    }
    private var dividers: [Pane: SplitDivider] = [:]
    /// Divider positions from before the assistant opened, kept until restored.
    private var savedPositions: [Pane: CGFloat] = [:]
    private var isPresented = false
    private var remainingAttempts = 0
    private var scheduled = false

    func beginPresentation() {
        guard !isPresented else { return }
        isPresented = true
        remainingAttempts = 0
        // A restore that hasn't finished still holds the user's positions.
        guard savedPositions.isEmpty else { return }
        savedPositions = dividers.compactMapValues { divider in
            guard let split = divider.split, let pane = divider.pane, !split.isSubviewCollapsed(pane) else { return nil }
            return pane.frame.maxX
        }
    }

    func endPresentation() {
        guard isPresented else { return }
        isPresented = false
        requestApply()
    }

    func attach(_ divider: EnclosingSplitDivider, as role: Pane) {
        let old = dividers[role]
        dividers[role] = SplitDivider(split: divider.split, pane: divider.pane, index: divider.index)
        if old?.split !== divider.split || old?.pane !== divider.pane { requestApply() }
    }

    /// SwiftUI can apply column constraints after updating the representable.
    /// Retry only while layout is settling, with a fixed budget and no animation.
    func requestApply() {
        guard !isPresented, !savedPositions.isEmpty else { return }
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
        guard !isPresented, !savedPositions.isEmpty, remainingAttempts > 0 else { return }
        var settled = true
        var outOfReach = false
        for (role, position) in savedPositions {
            // Wait for a column that SwiftUI hasn't brought back yet.
            guard let divider = dividers[role], let split = divider.split, let pane = divider.pane,
                  divider.index < split.arrangedSubviews.count - 1,
                  split.arrangedSubviews[divider.index] === pane,
                  !split.isSubviewCollapsed(pane) else {
                settled = false
                continue
            }
            if abs(pane.frame.maxX - position) > 0.5 {
                let lower = split.minPossiblePositionOfDivider(at: divider.index)
                let upper = split.maxPossiblePositionOfDivider(at: divider.index)
                // The split can still have its narrower presented width. A clamped
                // position would stick, so wait for the pass that widens it.
                if position < lower - 0.5 || position > upper + 0.5 { outOfReach = true }
                else { split.setPosition(position, ofDividerAt: divider.index) }
            }
            settled = settled && abs(pane.frame.maxX - position) <= 0.5
        }
        if settled {
            remainingAttempts = 0
            savedPositions = [:]
        } else if !outOfReach {
            remainingAttempts -= 1
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
