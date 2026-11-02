#if DEBUG || TERN_PERFORMANCE
import AppKit
import Foundation

/// Opt-in geometry evidence. No mail identities, content, or native objects enter reports.
@MainActor
final class ReaderLayoutDiagnostics {
    static let capacity = 4_096
    static let shared: ReaderLayoutDiagnostics? = destination(in: ProcessInfo.processInfo.arguments)
        .map { ReaderLayoutDiagnostics(destination: $0) }

    static func allocateToken() -> UInt64 { shared?.nextToken() ?? 0 }

    static func destination(in arguments: [String]) -> URL? {
        let prefix = "--reader-layout-report="
        let options = arguments.filter { $0.hasPrefix(prefix) }
        guard options.count == 1, let option = options.first else { return nil }
        let path = String(option.dropFirst(prefix.count))
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path)
    }

    struct Epoch: Codable, Sendable, Equatable {
        var documentRevision = 0
        var roundedWidthGeneration: UInt64 = 0
        var activationGeneration: UInt64 = 0
    }

    struct RendererState {
        let token: UInt64
        var epoch = Epoch()
        var active = true
        var readable = false
    }

    enum RendererPhase: String, Codable, Sendable { case create, load, activation, height, frame, dismantle }
    enum HeightSource: String, Codable, Sendable { case script, nativeEvaluation }
    enum VisibilityPhase: String, Codable, Sendable { case update, attach, schedule, coalesce, deliver, deduplicate, stop }

    struct WindowSnapshot: Codable, Sendable {
        let token: UInt64?
        let attached: Bool
        let visible: Bool?
        let miniaturized: Bool?
        let unoccluded: Bool?
    }

    struct RendererEvent: Codable, Sendable {
        let token: UInt64
        let phase: RendererPhase
        let epoch: Epoch
        /// Only native evaluations have a captured request epoch. Script posts do not.
        let requestEpoch: Epoch?
        let heightSource: HeightSource?
        let previousActive: Bool?
        let requestedActive: Bool?
        let active: Bool
        let readable: Bool
        let hidden: Bool
        let window: WindowSnapshot
        let scale: Double?
        let frameWidth: Double?
        let frameHeight: Double?
        let roundedWidth: Double?
        let oldFrameWidth: Double?
        let oldFrameHeight: Double?
        let proposedFrameWidth: Double?
        let proposedFrameHeight: Double?
        /// Values received from the existing JS protocol, already rounded there.
        let receivedHeight: Double?
        let oldBindingHeight: Double?
        let publishedHeight: Bool?
    }

    struct VisibilityEvent: Codable, Sendable {
        let observerToken: UInt64
        let ownerToken: UInt64
        let queuedOwnerToken: UInt64?
        let callbackGeneration: UInt64
        let queuedCallbackGeneration: UInt64?
        let phase: VisibilityPhase
        /// 1 update, 2 attachment, 4 occlusion, 8 miniaturize, 16 deminiaturize.
        let reasonBits: UInt32
        let window: WindowSnapshot
        let reported: Bool?
        let sampledVisible: Bool?
        let ownerVisible: Bool
        let scheduled: Bool
        let stopped: Bool
    }

    struct Event: Codable, Sendable {
        let sequence: UInt64
        let elapsedMilliseconds: Double
        let renderer: RendererEvent?
        let visibility: VisibilityEvent?
    }

    struct Report: Codable, Sendable {
        let version: Int
        let capacity: Int
        let stopped: Bool
        let totalEvents: UInt64
        let overwrittenEvents: UInt64
        let invalidHeights: UInt64
        let windowTokenDrops: UInt64
        let exportFailures: UInt64
        let events: [Event]
    }

    private struct WeakWindow {
        weak var window: NSWindow?
        let token: UInt64
    }

    private let started = ContinuousClock.now
    private let exporter: ReaderLayoutExporter
    private var slots = [Event?](repeating: nil, count: ReaderLayoutDiagnostics.capacity)
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var token: UInt64 = 0
    private var sequence: UInt64 = 0
    private var invalidHeights: UInt64 = 0
    private var windowTokenDrops: UInt64 = 0
    private var exportFailures: UInt64 = 0
    private var revision: UInt64 = 0
    private var isStopped = false
    private var checkpoint: Task<Void, Never>?

    init(destination: URL) { exporter = ReaderLayoutExporter(destination: destination) }

    func nextToken() -> UInt64 { token &+= 1; return token }

    func register(_ view: ContentSizedWebView) {
        guard !isStopped, view.readerLayoutState == nil else { return }
        view.readerLayoutState = RendererState(token: nextToken())
        recordRenderer(view, phase: .create)
    }

    func recordRenderer(_ view: ContentSizedWebView, phase: RendererPhase,
                        documentRevision: Int? = nil, active: Bool? = nil, readable: Bool? = nil,
                        previousActive: Bool? = nil, requestedActive: Bool? = nil,
                        widthChanged: Bool = false, oldFrame: NSSize? = nil, proposedFrame: NSSize? = nil,
                        heightSource: HeightSource? = nil, requestEpoch: Epoch? = nil,
                        receivedHeight: Double? = nil, oldBindingHeight: Double? = nil, publishedHeight: Bool? = nil) {
        guard !isStopped, var state = view.readerLayoutState else { return }
        if let documentRevision { state.epoch.documentRevision = documentRevision }
        if let active {
            if state.active != active { state.epoch.activationGeneration &+= 1 }
            state.active = active
        }
        if let readable { state.readable = readable }
        if widthChanged { state.epoch.roundedWidthGeneration &+= 1 }
        view.readerLayoutState = state
        if let receivedHeight, !receivedHeight.isFinite { invalidHeights &+= 1 }
        let frame = view.frame.size
        let scale = view.window?.backingScaleFactor ?? 2
        append(renderer: RendererEvent(token: state.token, phase: phase, epoch: state.epoch,
            requestEpoch: requestEpoch, heightSource: heightSource, previousActive: previousActive,
            requestedActive: requestedActive, active: state.active, readable: state.readable,
            hidden: view.isHidden, window: snapshot(view.window), scale: finite(scale),
            frameWidth: finite(frame.width), frameHeight: finite(frame.height),
            roundedWidth: finite((frame.width * scale).rounded()),
            oldFrameWidth: oldFrame.flatMap { finite($0.width) }, oldFrameHeight: oldFrame.flatMap { finite($0.height) },
            proposedFrameWidth: proposedFrame.flatMap { finite($0.width) }, proposedFrameHeight: proposedFrame.flatMap { finite($0.height) },
            receivedHeight: receivedHeight.flatMap(finite), oldBindingHeight: oldBindingHeight.flatMap(finite),
            publishedHeight: publishedHeight), visibility: nil)
    }

    func recordVisibility(observerToken: UInt64, ownerToken: UInt64, queuedOwnerToken: UInt64?,
                          callbackGeneration: UInt64, queuedCallbackGeneration: UInt64?,
                          phase: VisibilityPhase, reasonBits: UInt32, window: NSWindow?,
                          reported: Bool?, sampledVisible: Bool?, ownerVisible: Bool, scheduled: Bool, stopped: Bool) {
        guard !isStopped else { return }
        append(renderer: nil, visibility: VisibilityEvent(observerToken: observerToken, ownerToken: ownerToken,
            queuedOwnerToken: queuedOwnerToken, callbackGeneration: callbackGeneration,
            queuedCallbackGeneration: queuedCallbackGeneration, phase: phase, reasonBits: reasonBits,
            window: snapshot(window), reported: reported, sampledVisible: sampledVisible, ownerVisible: ownerVisible,
            scheduled: scheduled, stopped: stopped))
    }

    /// Controlled harnesses can await this. Live checkpoints remain explicitly incomplete.
    func stop() async -> Bool {
        isStopped = true
        let pending = checkpoint
        pending?.cancel()
        await pending?.value
        checkpoint = nil
        return await exporter.write(report())
    }

    func report() -> Report {
        let count = min(sequence, UInt64(Self.capacity))
        let first = sequence - count
        let events = (first..<sequence).compactMap { slots[Int($0 % UInt64(Self.capacity))] }
        return Report(version: 1, capacity: Self.capacity, stopped: isStopped, totalEvents: sequence,
                      overwrittenEvents: sequence - count, invalidHeights: invalidHeights,
                      windowTokenDrops: windowTokenDrops, exportFailures: exportFailures, events: events)
    }

    private func append(renderer: RendererEvent?, visibility: VisibilityEvent?) {
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        slots[Int(sequence % UInt64(Self.capacity))] = Event(sequence: sequence, elapsedMilliseconds: milliseconds,
                                                           renderer: renderer, visibility: visibility)
        sequence &+= 1
        revision &+= 1
        scheduleCheckpoint()
    }

    private func scheduleCheckpoint() {
        guard checkpoint == nil, !isStopped else { return }
        checkpoint = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !self.isStopped else { return }
            let revision = self.revision
            let success = await self.exporter.write(self.report())
            if !success { self.exportFailures &+= 1 }
            self.checkpoint = nil
            if self.revision != revision { self.scheduleCheckpoint() }
        }
    }

    private func snapshot(_ window: NSWindow?) -> WindowSnapshot {
        guard let window else {
            return WindowSnapshot(token: nil, attached: false, visible: nil, miniaturized: nil, unoccluded: nil)
        }
        let key = ObjectIdentifier(window)
        if windows[key]?.window !== window {
            windows = windows.filter { $0.value.window != nil }
            if windows.count < 32 { windows[key] = WeakWindow(window: window, token: nextToken()) }
            else { windowTokenDrops &+= 1 }
        }
        return WindowSnapshot(token: windows[key]?.token, attached: true, visible: window.isVisible,
                              miniaturized: window.isMiniaturized, unoccluded: window.occlusionState.contains(.visible))
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
}

private actor ReaderLayoutExporter {
    private let destination: URL
    init(destination: URL) { self.destination = destination }

    func write(_ report: ReaderLayoutDiagnostics.Report) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: destination, options: .atomic)
            return true
        } catch { return false }
    }
}
#endif
