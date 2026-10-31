import AppKit
import SwiftUI

/// Reports the native split around a mail column to the pane sizing and the
/// toolbar inset. Each probe sees only its own ancestors.
struct MailColumnProbe: NSViewRepresentable {
    let sizing: AssistantMailPaneSizing
    let toolbarInset: ClippedSplitToolbarInset
    let pane: AssistantMailPaneSizing.Pane
    let isPresented: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.sizing = sizing; view.toolbarInset = toolbarInset; view.pane = pane
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
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
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
