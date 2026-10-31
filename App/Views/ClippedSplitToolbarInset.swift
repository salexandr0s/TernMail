import AppKit
import Observation

/// MainView clips the mail columns so a split wider than its frame never draws
/// over the assistant. SwiftUI then drops the split view's toolbar safe area,
/// and on macOS 26 the columns start beneath the toolbar. Measure the split
/// once layout has settled so each column can reserve the missing inset.
@Observable @MainActor
final class ClippedSplitToolbarInset {
    private(set) var top: CGFloat = 0
    @ObservationIgnored private weak var split: NSSplitView?
    @ObservationIgnored private var scheduled = false

    func measure(_ split: NSSplitView) {
        self.split = split
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            scheduled = false
            guard let split = self.split, let window = split.window else { return }
            let overlap = split.convert(split.bounds, to: nil).maxY - window.contentLayoutRect.maxY
            let missing = max(0, overlap - split.safeAreaInsets.top)
            if abs(top - missing) > 0.5 { top = missing }
        }
    }

    func refresh() {
        guard let split else { return }
        measure(split)
    }
}
