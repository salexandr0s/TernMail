import SwiftUI

/// Steps a new compose window down and right while it would open exactly on
/// top of another one.
struct ComposeWindowCascade: NSViewRepresentable {
    func makeNSView(context: Context) -> CascadeView { CascadeView() }

    func updateNSView(_ nsView: CascadeView, context: Context) {}

    final class CascadeView: NSView {
        /// Compose windows already placed, which a new one steps away from.
        private static let placed = NSHashTable<NSWindow>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !Self.placed.contains(window) else { return }
            let others = Self.placed.allObjects.filter(\.isVisible)
            Self.placed.add(window)
            // A window that opens as a tab takes its group's frame, so it has nowhere to step.
            let opensAsTab = switch NSWindow.userTabbingPreference {
            case .always: true
            case .inFullScreen: others.contains { $0.styleMask.contains(.fullScreen) }
            default: false
            }
            guard !opensAsTab, !window.styleMask.contains(.fullScreen) else { return }
            func covers(_ other: NSWindow) -> Bool {
                abs(other.frame.minX - window.frame.minX) < 1 && abs(other.frame.maxY - window.frame.maxY) < 1
            }
            var next = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            // One step more than there are other windows is enough to clear them all.
            for _ in 0...others.count where others.contains(where: covers) {
                next = window.cascadeTopLeft(from: next)
            }
        }
    }
}
