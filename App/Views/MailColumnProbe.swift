import AppKit
import SwiftUI

/// Reports the native split around a mail column to the pane sizing and the
/// toolbar inset. Each probe sees only its own ancestors.
struct MailColumnProbe: NSViewRepresentable {
    let sizing: AssistantMailPaneSizing
    let toolbarInset: ClippedSplitToolbarInset
    let pane: AssistantMailPaneSizing.Pane
    let isPresented: Bool
    var toolbarSidebarWidth: CGFloat? = nil

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.sizing = sizing; view.toolbarInset = toolbarInset; view.pane = pane
        sizing.setToolbarSidebarWidth(toolbarSidebarWidth)
        view.attach()
        if view.isPresented != isPresented {
            view.isPresented = isPresented
            sizing.requestApply()
        }
    }

    final class ProbeView: NSView {
        weak var sizing: AssistantMailPaneSizing?
        weak var toolbarInset: ClippedSplitToolbarInset?
        var pane = AssistantMailPaneSizing.Pane.navigation
        var isPresented = false
        #if DEBUG || TERN_PERFORMANCE
        private(set) var windowAttachmentCount = 0
        private(set) var windowDetachmentCount = 0
        private(set) var superviewMoveCount = 0
        #endif
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            #if DEBUG || TERN_PERFORMANCE
            if window == nil { windowDetachmentCount += 1 } else { windowAttachmentCount += 1 }
            #endif
            attach()
        }
        #if DEBUG || TERN_PERFORMANCE
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            superviewMoveCount += 1
        }
        #endif
        override func layout() {
            super.layout()
            attach()
            sizing?.schedulePendingApply()
        }

        func attach() {
            guard let divider = EnclosingSplitDivider(of: self) else { return }
            toolbarInset?.measure(divider.split)
            sizing?.attach(divider, as: pane)
        }
    }
}
