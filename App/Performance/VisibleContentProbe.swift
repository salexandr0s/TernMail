import AppKit
import SwiftUI

/// Observes a drawing commit without forcing layout or blocking the main thread.
/// Place inside the destination content, never on a loading overlay or toolbar.
struct VisibleContentProbe: NSViewRepresentable {
    let kind: NavigationInteractionKind
    let isActive: Bool
    let revision: Int

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(kind: kind, isActive: isActive, revision: revision)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: Void) { view.stop() }

    @MainActor
    final class ProbeView: NSView {
        var kind: NavigationInteractionKind = .reader
        var isActive = false
        private var revision = 0
        private var observer: UUID?
        private var scheduledGeneration: UInt64?
        private let performance: NavigationPerformance

        init(performance: NavigationPerformance = .shared) {
            self.performance = performance
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }

        func configure(kind: NavigationInteractionKind, isActive: Bool, revision: Int) {
            let changed = observer == nil || self.kind != kind || self.isActive != isActive || self.revision != revision
            self.kind = kind
            self.isActive = isActive
            self.revision = revision
            if observer == nil {
                observer = performance.observe { [weak self] changed in
                    guard let self, changed == self.kind else { return }
                    self.needsDisplay = true
                }
            }
            if changed { needsDisplay = true }
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard isVisibleContent,
                  let generation = performance.currentGeneration(for: kind),
                  performance.isReady(kind, generation: generation), scheduledGeneration != generation else { return }
            scheduledGeneration = generation
            let kind = kind
            // AppKit has issued the native drawing work. Defer the endpoint until
            // this transaction returns, rechecking that selection is still current.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.kind == kind, self.isVisibleContent else { return }
                self.performance.didCommitVisibleContent(kind, generation: generation)
            }
        }

        var isVisibleContent: Bool {
            guard isActive, NSApp?.isActive == true, let window, window.isVisible, !window.isMiniaturized,
                  window.isKeyWindow || window.isMainWindow,
                  window.occlusionState.contains(.visible), !visibleRect.isEmpty,
                  !isHiddenOrHasHiddenAncestor else { return false }
            var current: NSView? = self
            while let view = current {
                guard view.alphaValue > 0.01 else { return false }
                current = view.superview
            }
            return true
        }

        func stop() {
            if let observer { performance.removeObserver(observer) }
            observer = nil
            isActive = false
        }
    }
}
