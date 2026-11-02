import AppKit
import SwiftUI

/// Horizontal scrolling changes the period without taking pointer events from the grid.
struct CalendarScrollNavigation: NSViewRepresentable {
    var isEnabled: Bool
    let navigate: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.navigate = navigate
        view.isEnabled = isEnabled
        view.updateMonitor()
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var isEnabled = false
        var navigate: ((Int) -> Void)?
        private var monitor: Any?
        private var gesture = CalendarScrollGesture()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        func updateMonitor() {
            guard isEnabled, window != nil else { stop(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // AppKit invokes local event monitors synchronously on the main thread.
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            gesture = CalendarScrollGesture()
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard isEnabled, let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty,
                  visibleRect.contains(convert(event.locationInWindow, from: nil)),
                  event.hasPreciseScrollingDeltas,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  NSEvent.pressedMouseButtons == 0 else {
                gesture.cancel(at: event.timestamp)
                return false
            }
            let result = gesture.handle(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                        phase: event.phase, momentumPhase: event.momentumPhase,
                                        timestamp: event.timestamp)
            if let direction = result.direction { navigate?(direction) }
            return result.consumesEvent
        }
    }
}

/// Phase-less devices delimit gestures by an idle gap; trackpads use AppKit's phases.
struct CalendarScrollGesture {
    struct Result: Equatable {
        var direction: Int? = nil
        var consumesEvent = false
    }

    private enum Axis { case horizontal, vertical }
    private var axis: Axis?
    private var distanceX: CGFloat = 0
    private var distanceY: CGFloat = 0
    private var displacementX: CGFloat = 0
    private var navigated = false
    private var ignoresContinuation = true
    private var lastTimestamp: TimeInterval?

    // Input distances are in scrolling points, independent of visual layout tokens.
    private static let axisThreshold: CGFloat = 8
    private static let navigationThreshold: CGFloat = 36
    private static let horizontalDominance: CGFloat = 1.35
    private static let idleInterval: TimeInterval = 0.3

    mutating func cancel(at timestamp: TimeInterval) {
        self = Self()
        lastTimestamp = timestamp
    }

    mutating func handle(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
                         momentumPhase: NSEvent.Phase, timestamp: TimeInterval) -> Result {
        let startsGesture = phase.contains(.began) || phase.contains(.mayBegin)
        let startsUnphasedGesture = phase.isEmpty && momentumPhase.isEmpty
            && (lastTimestamp.map { timestamp - $0 > Self.idleInterval } ?? true)
        if startsGesture || startsUnphasedGesture {
            self = Self()
            ignoresContinuation = false
        }
        lastTimestamp = timestamp

        // Momentum must never start another period change, even after a long pause.
        if !momentumPhase.isEmpty { return Result(consumesEvent: axis == .horizontal) }
        if phase.contains(.cancelled) {
            ignoresContinuation = true
            return Result(consumesEvent: axis == .horizontal)
        }
        guard !ignoresContinuation, deltaX.isFinite, deltaY.isFinite else { return Result() }
        defer {
            if phase.contains(.ended) { ignoresContinuation = true }
        }

        distanceX += abs(deltaX)
        distanceY += abs(deltaY)
        displacementX += deltaX
        if axis == nil, max(distanceX, distanceY) >= Self.axisThreshold {
            if distanceX > distanceY * Self.horizontalDominance { axis = .horizontal }
            else if distanceY >= distanceX { axis = .vertical }
        }
        guard axis == .horizontal else { return Result() }
        guard !navigated, abs(displacementX) >= Self.navigationThreshold else {
            return Result(consumesEvent: true)
        }
        navigated = true
        // Native deltas describe content movement: moving content left reveals the next period.
        return Result(direction: displacementX < 0 ? 1 : -1, consumesEvent: true)
    }
}
