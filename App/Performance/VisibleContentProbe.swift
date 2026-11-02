import AppKit
import SwiftUI

/// Observes a drawing commit without forcing layout or blocking the main thread.
/// Place inside the destination content, never on a loading overlay or toolbar.
struct VisibleContentProbe: NSViewRepresentable {
    let kinds: Set<NavigationInteractionKind>
    let isActive: Bool
    let revision: Int
    private let selectedRow: SelectedRowRequirement?

    struct SelectedRowIdentity: Equatable {
        let owner: ObjectIdentifier
        let accountOwner: ObjectIdentifier
        let row: MailListRowID
    }

    struct SelectedRowRequirement {
        let identity: SelectedRowIdentity
        let isCurrent: @MainActor () -> Bool
    }

    init(kind: NavigationInteractionKind, isActive: Bool, revision: Int) {
        self.init(kinds: [kind], isActive: isActive, revision: revision)
    }

    init(kinds: [NavigationInteractionKind], isActive: Bool, revision: Int) {
        self.kinds = Set(kinds)
        self.isActive = isActive
        self.revision = revision
        selectedRow = nil
    }

    init(selectedRow: SelectedRowRequirement, isActive: Bool) {
        kinds = [.selectionFeedback]
        self.isActive = isActive
        revision = 0
        self.selectedRow = selectedRow
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(kinds: kinds, isActive: isActive, revision: revision, selectedRow: selectedRow)
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
        private var selectedRow: SelectedRowRequirement?
        private weak var observedTable: NSTableView?
        private var tableSelectionObserver: NSObjectProtocol?
        private var isStopped = false
        #if DEBUG || TERN_PERFORMANCE
        private(set) var windowAttachmentCount = 0
        private(set) var windowDetachmentCount = 0
        private(set) var superviewMoveCount = 0
        private(set) var displayRequestCount = 0
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

        func configure(kinds: Set<NavigationInteractionKind>, isActive: Bool, revision: Int,
                       selectedRow: SelectedRowRequirement? = nil) {
            isStopped = false
            let changed = observer == nil || self.kinds != kinds || self.isActive != isActive
                || self.revision != revision || self.selectedRow?.identity != selectedRow?.identity
            self.kinds = kinds
            self.isActive = isActive
            self.revision = revision
            self.selectedRow = selectedRow
            if changed {
                configuration &+= 1
                scheduled.removeAll(keepingCapacity: true)
                requestProbeDisplay()
            }
            installObservers()
        }

        private var currentSelectionPermitsDisplay: Bool {
            guard let selectedRow else { return true }
            return performance.selectionFeedbackEnabled && isActive && selectedRow.isCurrent()
        }

        private func requestProbeDisplay() {
            guard !isStopped else { return }
            // One selected probe can invalidate itself. A selection event must
            // not deliberately dirty every realized row's native diagnostic view.
            if currentSelectionPermitsDisplay {
                #if DEBUG || TERN_PERFORMANCE
                displayRequestCount &+= 1
                #endif
                needsDisplay = true
            }
        }

        private func installObservers() {
            guard !isStopped else { return }
            if observer == nil {
                observer = performance.observe { [weak self] changed in
                    guard let self, self.kinds.contains(changed) else { return }
                    self.requestProbeDisplay()
                }
            }
            if selectedRow != nil {
                performance.registerFeedbackProbe(self)
                bindTableSelectionObserver()
            } else {
                removeTableSelectionObserver()
                performance.unregisterFeedbackProbe(self)
            }
        }

        private func nativeRowAndTable() -> (NSTableRowView, NSTableView)? {
            var ancestor = superview
            var row: NSTableRowView?
            while let view = ancestor {
                if row == nil { row = view as? NSTableRowView }
                if let table = view as? NSTableView, let row { return (row, table) }
                ancestor = view.superview
            }
            return nil
        }

        private func bindTableSelectionObserver() {
            let table = window == nil ? nil : nativeRowAndTable()?.1
            if observedTable === table, tableSelectionObserver != nil { return }
            removeTableSelectionObserver()
            guard let table else { return }
            observedTable = table
            tableSelectionObserver = NotificationCenter.default.addObserver(
                forName: NSTableView.selectionDidChangeNotification, object: table, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestProbeDisplay() }
            }
        }

        private func removeTableSelectionObserver() {
            if let tableSelectionObserver { NotificationCenter.default.removeObserver(tableSelectionObserver) }
            tableSelectionObserver = nil
            observedTable = nil
        }

        /// Native state and viewport gate; independent of app foreground so
        /// background structural tests can validate it without faking a commit.
        var satisfiesSelectedRowRequirement: Bool {
            guard selectedRow != nil else { return true }
            guard currentSelectionPermitsDisplay, let (row, table) = nativeRowAndTable(),
                  row.window === window, table.window === window, window != nil,
                  row.isSelected, !row.isHiddenOrHasHiddenAncestor else { return false }
            let index = table.row(for: row)
            guard index >= 0, table.selectedRowIndexes == IndexSet(integer: index),
                  !visibleRect.isEmpty, !row.visibleRect.isEmpty else { return false }
            let rowRect = row.convert(row.bounds, to: table)
            let probeRect = convert(visibleRect, to: table)
            return rowRect.intersects(table.visibleRect) && probeRect.intersects(table.visibleRect)
                && probeRect.intersects(rowRect)
        }

        /// Snapshot readiness independently for every interaction sharing this
        /// exact content viewport. Reading it does not complete an interaction.
        func readyDrawingCommits() -> [DrawingCommit] {
            guard isActive, satisfiesSelectedRowRequirement else { return [] }
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
                && satisfiesSelectedRowRequirement
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            #if DEBUG || TERN_PERFORMANCE
            if window == nil { windowDetachmentCount += 1 } else { windowAttachmentCount += 1 }
            #endif
            guard !isStopped else { return }
            if selectedRow != nil, window == nil {
                removeObservers()
                configuration &+= 1
                scheduled.removeAll(keepingCapacity: true)
            } else {
                // A native move may reattach without another SwiftUI configure.
                installObservers()
                requestProbeDisplay()
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            #if DEBUG || TERN_PERFORMANCE
            superviewMoveCount += 1
            #endif
            guard !isStopped else { return }
            if selectedRow != nil, window != nil {
                installObservers()
                requestProbeDisplay()
            }
        }

        override func layout() {
            super.layout()
            if !isStopped, selectedRow != nil, window != nil { bindTableSelectionObserver() }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard !isStopped else { return }
            if selectedRow != nil { bindTableSelectionObserver() }
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
                  !isHiddenOrHasHiddenAncestor, satisfiesSelectedRowRequirement else { return false }
            var current: NSView? = self
            while let view = current {
                guard view.alphaValue > 0.01 else { return false }
                current = view.superview
            }
            return true
        }

        private func removeObservers() {
            if let observer { performance.removeObserver(observer) }
            observer = nil
            removeTableSelectionObserver()
            performance.unregisterFeedbackProbe(self)
        }

        func stop() {
            removeObservers()
            isStopped = true
            isActive = false
            configuration &+= 1
            scheduled.removeAll(keepingCapacity: true)
        }
    }
}
