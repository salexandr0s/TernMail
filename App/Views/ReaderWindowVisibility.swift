import AppKit
import SwiftUI

/// Selected readers suspend automatic work when their window is minimized or
/// fully occluded. A visible background window can still be read.
struct ReaderWindowVisibility: NSViewRepresentable {
    var didChange: (Bool) -> Void
    #if DEBUG || TERN_PERFORMANCE
    var auditSnapshot: (@MainActor () -> (ownerToken: UInt64, ownerVisible: Bool))? = nil
    #endif

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.didChange = didChange
        #if DEBUG || TERN_PERFORMANCE
        view.configureAudit(snapshot: auditSnapshot)
        #endif
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.didChange = didChange
        #if DEBUG || TERN_PERFORMANCE
        view.configureAudit(snapshot: auditSnapshot)
        #endif
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: Void) { view.stop() }

    @MainActor final class ObserverView: NSView {
        var didChange: (Bool) -> Void = { _ in }
        private var observations: [any NSObjectProtocol] = []
        private var reported: Bool?
        private var scheduled = false
        private var stopped = false
        #if DEBUG || TERN_PERFORMANCE
        private let auditObserverToken = ReaderLayoutDiagnostics.allocateToken()
        private var auditOwnerToken: UInt64 = 0
        private var auditOwnerVisible = false
        private var auditCallbackGeneration: UInt64 = 0
        private var auditQueuedOwnerToken: UInt64?
        private var auditQueuedCallbackGeneration: UInt64?
        private var auditPendingReasons: UInt32 = 0

        func configureAudit(snapshot: (@MainActor () -> (ownerToken: UInt64, ownerVisible: Bool))?) {
            let value = snapshot?()
            auditOwnerToken = value?.ownerToken ?? 0
            auditOwnerVisible = value?.ownerVisible ?? false
            auditCallbackGeneration &+= 1
            recordAudit(.update, reasonBits: 1)
        }

        private func recordAudit(_ phase: ReaderLayoutDiagnostics.VisibilityPhase,
                                 reasonBits: UInt32? = nil, sampledVisible: Bool? = nil) {
            ReaderLayoutDiagnostics.shared?.recordVisibility(observerToken: auditObserverToken,
                ownerToken: auditOwnerToken, queuedOwnerToken: auditQueuedOwnerToken,
                callbackGeneration: auditCallbackGeneration, queuedCallbackGeneration: auditQueuedCallbackGeneration,
                phase: phase, reasonBits: reasonBits ?? auditPendingReasons, window: window,
                reported: reported, sampledVisible: sampledVisible, ownerVisible: auditOwnerVisible,
                scheduled: scheduled, stopped: stopped)
        }
        #endif

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservations()
            if let window {
                for (name, reasonBits) in [(NSWindow.didChangeOcclusionStateNotification, UInt32(4)),
                                          (NSWindow.didMiniaturizeNotification, UInt32(8)),
                                          (NSWindow.didDeminiaturizeNotification, UInt32(16))] {
                    observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.scheduleUpdate(reasonBits: reasonBits) }
                    })
                }
            }
            #if DEBUG || TERN_PERFORMANCE
            recordAudit(.attach, reasonBits: 2)
            #endif
            scheduleUpdate(reasonBits: 2)
        }
        /// Audit reasons: callback update=1, attachment=2, occlusion=4,
        /// miniaturize=8, deminiaturize=16. Existing notifications are unchanged.
        func scheduleUpdate(reasonBits: UInt32 = 1) {
            #if DEBUG || TERN_PERFORMANCE
            auditPendingReasons |= reasonBits
            if scheduled || stopped { recordAudit(.coalesce) }
            #endif
            guard !scheduled, !stopped else { return }
            scheduled = true
            #if DEBUG || TERN_PERFORMANCE
            auditQueuedOwnerToken = auditOwnerToken
            auditQueuedCallbackGeneration = auditCallbackGeneration
            recordAudit(.schedule)
            #endif
            // NSViewRepresentable updates must not mutate SwiftUI state.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.scheduled = false
                let visible = self.window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
                #if DEBUG || TERN_PERFORMANCE
                self.recordAudit(self.reported == visible ? .deduplicate : .deliver, sampledVisible: visible)
                self.auditPendingReasons = 0
                self.auditQueuedOwnerToken = nil
                self.auditQueuedCallbackGeneration = nil
                #endif
                guard self.reported != visible else { return }
                self.reported = visible
                self.didChange(visible)
            }
        }
        func stop() {
            stopped = true
            #if DEBUG || TERN_PERFORMANCE
            recordAudit(.stop)
            #endif
            removeObservations()
        }
        private func removeObservations() {
            for observation in observations { NotificationCenter.default.removeObserver(observation) }
            observations.removeAll()
        }
    }
}
