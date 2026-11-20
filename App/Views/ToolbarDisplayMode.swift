import AppKit
import Observation

/// Whether a window's toolbar shows a label under each item, as it does in
/// Icon and Text mode. The items are wider then, so `WorkspaceToolbarLayout`
/// folds controls at wider windows.
@MainActor @Observable final class ToolbarDisplayMode {
    private(set) var showsLabels = false
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var windowObservation: NSKeyValueObservation?
    @ObservationIgnored private var toolbarObservation: NSKeyValueObservation?

    /// Every instance that follows a window. AppKit gives a toolbar's new mode
    /// to every toolbar with the same identifier, but only the changed toolbar
    /// tells its observers. So a change seen by one instance makes each of
    /// them read its own toolbar again.
    private static let followers = NSHashTable<ToolbarDisplayMode>.weakObjects()

    /// Follows `window`'s toolbar, including one SwiftUI gives the window later.
    func follow(_ window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        Self.followers.add(self)
        windowObservation = window.observe(\.toolbar) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.toolbarChanged() }
        }
        toolbarChanged()
    }

    private func toolbarChanged() {
        toolbarObservation = window?.toolbar?.observe(\.displayMode) { @Sendable _, _ in
            Task { @MainActor in
                for follower in Self.followers.allObjects { follower.update() }
            }
        }
        update()
    }

    private func update() {
        let labels = switch window?.toolbar?.displayMode {
        case .iconAndLabel?, .labelOnly?: true
        default: false
        }
        if labels != showsLabels { showsLabels = labels }
    }
}
