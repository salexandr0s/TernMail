import AppKit
import SwiftUI

/// Selected readers suspend automatic work when their window is minimized or
/// fully occluded. A visible background window can still be read.
struct ReaderWindowVisibility: NSViewRepresentable {
    var didChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.didChange = didChange
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.didChange = didChange
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: Void) { view.stop() }

    @MainActor final class ObserverView: NSView {
        var didChange: (Bool) -> Void = { _ in }
        private var observations: [any NSObjectProtocol] = []
        private var reported: Bool?
        private var scheduled = false
        private var stopped = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservations()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification] {
                    observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.scheduleUpdate() }
                    })
                }
            }
            scheduleUpdate()
        }
        func scheduleUpdate() {
            guard !scheduled, !stopped else { return }
            scheduled = true
            // NSViewRepresentable updates must not mutate SwiftUI state.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.scheduled = false
                let visible = self.window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
                guard self.reported != visible else { return }
                self.reported = visible
                self.didChange(visible)
            }
        }
        func stop() { stopped = true; removeObservations() }
        private func removeObservations() {
            for observation in observations { NotificationCenter.default.removeObserver(observation) }
            observations.removeAll()
        }
    }
}
