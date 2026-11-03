import AppKit
import SwiftUI

/// Keeps the native divider and detail view in place while a sidebar slides
/// out of the window. The extra width gives the detail column its new space
/// before the hidden sidebar is removed from the split.
struct TernSidebarSplit<Sidebar: View, Detail: View>: View {
    let isPresented: Bool
    @Binding var sidebarWidth: CGFloat
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    let sidebar: () -> Sidebar
    let detail: () -> Detail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isMounted: Bool
    @State private var hiddenWidth: CGFloat = 0
    @State private var isAnimating = false
    @State private var generation = 0
    @State private var pendingOpening: Int?

    init(isPresented: Bool, sidebarWidth: Binding<CGFloat>, minimumWidth: CGFloat,
         maximumWidth: CGFloat, @ViewBuilder sidebar: @escaping () -> Sidebar,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.isPresented = isPresented
        self._sidebarWidth = sidebarWidth
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.sidebar = sidebar
        self.detail = detail
        self._isMounted = State(initialValue: isPresented)
    }

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                if isMounted {
                    sidebar()
                        .frame(minWidth: minimumWidth, idealWidth: sidebarWidth, maxWidth: maximumWidth)
                        .background {
                            TernSidebarWidthProbe(width: sidebarWidth, recordsWidth: isPresented && !isAnimating, onReady: {
                                guard let currentGeneration = pendingOpening, currentGeneration == generation,
                                      isPresented, !reduceMotion else { return }
                                pendingOpening = nil
                                animate(to: 0, generation: currentGeneration)
                            }) { width in
                                if width >= minimumWidth, abs(sidebarWidth - width) > 0.5 { sidebarWidth = width }
                            }
                        }
                        .allowsHitTesting(isPresented && !isAnimating)
                        .accessibilityHidden(!isPresented)
                }
                detail()
            }
            .frame(width: geometry.size.width + hiddenWidth, height: geometry.size.height)
            .offset(x: -hiddenWidth)
        }
        .clipped()
        .onAppear { finishImmediately() }
        .onChange(of: isPresented) { _, _ in updatePresentation() }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { finishImmediately() }
        }
        .onDisappear {
            // Invalidate pending preparation and completion callbacks.
            generation += 1
        }
    }

    private func updatePresentation() {
        guard !reduceMotion else { finishImmediately(); return }
        generation += 1
        let currentGeneration = generation
        pendingOpening = nil
        let width = min(max(sidebarWidth, minimumWidth), maximumWidth)
        isAnimating = true

        if isPresented, !isMounted {
            withoutAnimation {
                hiddenWidth = width + Tokens.Border.hairline
                isMounted = true
                pendingOpening = currentGeneration
            }
        } else {
            animate(to: isPresented ? 0 : width + Tokens.Border.hairline,
                    generation: currentGeneration)
        }
    }

    private func animate(to width: CGFloat, generation currentGeneration: Int) {
        withAnimation(Tokens.Motion.standard(duration: Tokens.Motion.slow), completionCriteria: .removed) {
            hiddenWidth = width
        } completion: {
            guard generation == currentGeneration else { return }
            withoutAnimation {
                if !isPresented {
                    isMounted = false
                    hiddenWidth = 0
                }
                isAnimating = false
            }
        }
    }

    private func finishImmediately() {
        generation += 1
        withoutAnimation {
            isMounted = isPresented
            hiddenWidth = 0
            isAnimating = false
            pendingOpening = nil
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}

/// Restores a dragged width before revealing a native column and while the
/// split changes size, without changing the sidebar's frame constraints.
private struct TernSidebarWidthProbe: NSViewRepresentable {
    let width: CGFloat
    let recordsWidth: Bool
    let onReady: () -> Void
    let onMeasure: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.widthToRestore = width
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.preferredWidth = width
        view.recordsWidth = recordsWidth
        view.onMeasure = onMeasure
        view.onReady = onReady
        view.scheduleMeasurement()
    }

    final class Probe: NSView {
        var preferredWidth: CGFloat = 0
        var recordsWidth = false
        var onMeasure: ((CGFloat) -> Void)?
        var onReady: (() -> Void)?
        var widthToRestore: CGFloat?
        private var splitWidth: CGFloat?
        private var windowWidth: CGFloat?
        private var scheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleMeasurement() }
        override func layout() { super.layout(); scheduleMeasurement() }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                scheduled = false
                guard let window, let divider = EnclosingSplitDivider(of: self),
                      divider.split.bounds.width > 0 else { return }
                // SwiftUI proportionally resizes native split columns even
                // during a reveal. Restore each interpolated layout without
                // recording those temporary sizes as divider drags.
                if let previous = splitWidth, abs(previous - divider.split.bounds.width) > 0.5 {
                    widthToRestore = preferredWidth
                }
                let currentWindowWidth = window.contentLayoutRect.width
                if let previous = windowWidth, abs(previous - currentWindowWidth) > 0.5 {
                    widthToRestore = preferredWidth
                }
                windowWidth = currentWindowWidth
                splitWidth = divider.split.bounds.width
                if let width = widthToRestore {
                    let lower = divider.split.minPossiblePositionOfDivider(at: divider.index)
                    let upper = divider.split.maxPossiblePositionOfDivider(at: divider.index)
                    guard width >= lower, width <= upper else { return }
                    divider.split.setPosition(width, ofDividerAt: divider.index)
                    // A temporarily constrained column must not replace the
                    // dragged width while its window is becoming compact.
                    guard abs(divider.pane.frame.width - width) <= 0.5 else { return }
                    widthToRestore = nil
                }
                // The inserted column has its saved width before it appears.
                onReady?()
                guard recordsWidth else { return }
                let width = divider.pane.frame.width
                if width > 0 { onMeasure?(width) }
            }
        }
    }
}
