import AppKit
import SwiftUI

/// Observes a drawing commit without forcing layout or blocking the main thread.
/// Place inside the destination content, never on a loading overlay or toolbar.
struct VisibleContentProbe: NSViewRepresentable {
    let kinds: Set<NavigationInteractionKind>
    let isActive: Bool
    let revision: Int

    init(kind: NavigationInteractionKind, isActive: Bool, revision: Int) {
        self.init(kinds: [kind], isActive: isActive, revision: revision)
    }

    init(kinds: [NavigationInteractionKind], isActive: Bool, revision: Int) {
        self.kinds = Set(kinds)
        self.isActive = isActive
        self.revision = revision
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(kinds: kinds, isActive: isActive, revision: revision)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: Void) { view.stop() }

    @MainActor
    final class ProbeView: NSView {
        private(set) var kinds: Set<NavigationInteractionKind> = [.reader]
        var kind: NavigationInteractionKind? { kinds.count == 1 ? kinds.first : nil }
        struct DrawingCommit: Equatable {
            let kind: NavigationInteractionKind
            let generation: UInt64
            fileprivate let configuration: UInt64
        }
        var isActive = false
        private var revision = 0
        private var observer: UUID?
        private var scheduled: [NavigationInteractionKind: DrawingCommit] = [:]
        private var configuration: UInt64 = 0
        private let performance: NavigationPerformance
        #if DEBUG || TERN_PERFORMANCE
        private(set) var windowAttachmentCount = 0
        private(set) var windowDetachmentCount = 0
        private(set) var superviewMoveCount = 0
        #endif

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
            configure(kinds: [kind], isActive: isActive, revision: revision)
        }

        func configure(kinds: Set<NavigationInteractionKind>, isActive: Bool, revision: Int) {
            let changed = observer == nil || self.kinds != kinds || self.isActive != isActive || self.revision != revision
            self.kinds = kinds
            self.isActive = isActive
            self.revision = revision
            if changed {
                configuration &+= 1
                scheduled.removeAll(keepingCapacity: true)
                needsDisplay = true
            }
            if observer == nil {
                observer = performance.observe { [weak self] changed in
                    guard let self, self.kinds.contains(changed) else { return }
                    self.needsDisplay = true
                }
            }
        }

        /// Snapshot readiness independently for every interaction sharing this
        /// exact content viewport. Reading it does not complete an interaction.
        func readyDrawingCommits() -> [DrawingCommit] {
            guard isActive else { return [] }
            return NavigationInteractionKind.allCases.compactMap { kind in
                guard kinds.contains(kind), let generation = performance.currentGeneration(for: kind),
                      performance.isReady(kind, generation: generation) else { return nil }
                let commit = DrawingCommit(kind: kind, generation: generation, configuration: configuration)
                return scheduled[kind] == commit ? nil : commit
            }
        }

        func isCurrentDrawingCommit(_ commit: DrawingCommit) -> Bool {
            isActive && kinds.contains(commit.kind) && configuration == commit.configuration
                && performance.currentGeneration(for: commit.kind) == commit.generation
                && performance.isReady(commit.kind, generation: commit.generation)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            #if DEBUG || TERN_PERFORMANCE
            if window == nil { windowDetachmentCount += 1 } else { windowAttachmentCount += 1 }
            #endif
            needsDisplay = true
        }

        #if DEBUG || TERN_PERFORMANCE
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            superviewMoveCount += 1
        }
        #endif

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard isVisibleContent else { return }
            for commit in readyDrawingCommits() {
                scheduled[commit.kind] = commit
                // Every kind shares this native drawing transaction, but keeps
                // its own generation, readiness, and cancellation semantics.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.scheduled[commit.kind] == commit { self.scheduled[commit.kind] = nil }
                    guard self.isCurrentDrawingCommit(commit), self.isVisibleContent else { return }
                    self.performance.didCommitVisibleContent(commit.kind, generation: commit.generation)
                }
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
            configuration &+= 1
            scheduled.removeAll(keepingCapacity: true)
        }
    }
}
