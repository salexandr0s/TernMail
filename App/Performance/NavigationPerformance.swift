import AppKit
import Diagnostics
import Foundation

enum NavigationInteractionKind: String, CaseIterable, Codable, Sendable {
    case reader, mailbox, workspace, selectionFeedback, readerHeader

    var span: TernSpan {
        switch self {
        case .reader: .selectionToReader
        case .mailbox: .mailboxSwitchToList
        case .workspace: .workspaceSwitchToContent
        case .selectionFeedback: .selectionToFeedback
        case .readerHeader: .selectionToHeader
        }
    }
}

enum NavigationCacheTier: String, Codable, Sendable { case retained, prepared, local, network }

/// Correlates selection with ready content and its next native drawing commit.
/// GPU presentation and missed frames are measured separately in Instruments.
@MainActor
final class NavigationPerformance {
    static let shared = NavigationPerformance()

    enum Outcome: String, Codable, Sendable { case visibleCommit, superseded, cancelled, timedOut }
    enum TimingOrigin: String, Codable, Sendable { case input, programmatic }

    struct Record: Codable, Sendable {
        let generation: UInt64
        let kind: NavigationInteractionKind
        let destination: String?
        let cacheTier: NavigationCacheTier?
        let outcome: Outcome
        let timingOrigin: TimingOrigin
        let inputQueueDelayMilliseconds: Double?
        let contentReadyMilliseconds: Double?
        let elapsedMilliseconds: Double
    }

    struct Summary: Codable, Sendable {
        let count: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let p99Milliseconds: Double
        let maximumMilliseconds: Double

        init?(_ values: [Double]) {
            let sorted = values.sorted()
            guard let maximum = sorted.last else { return nil }
            func percentile(_ fraction: Double) -> Double {
                sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
            }
            count = sorted.count
            p50Milliseconds = percentile(0.5)
            p95Milliseconds = percentile(0.95)
            p99Milliseconds = percentile(0.99)
            maximumMilliseconds = maximum
        }
    }

    struct Report: Codable, Sendable {
        let endpoint: String
        let records: [Record]
        let summaries: [String: Summary]
        let stageSummaries: [String: Summary]
        let counters: [String: Int]
        let physicalFootprintBytes: UInt64?
    }

    enum Counter: String, Codable, Sendable {
        case preparedCacheHit, preparedCacheMiss, renderStarted, renderCancelled
        case webViewCreated, webViewDestroyed, heightReport, thumbnailDecoded
    }

    private struct Pending {
        let generation: UInt64
        let kind: NavigationInteractionKind
        let destination: String?
        let started: ContinuousClock.Instant
        let token: SpanToken
        let timingOrigin: TimingOrigin
        let inputQueueDelayMilliseconds: Double?
        var ready: ContinuousClock.Instant?
        var cacheTier: NavigationCacheTier?
    }

    private var nextGeneration: UInt64 = 0
    private var pending: [NavigationInteractionKind: Pending] = [:]
    private var observers: [UUID: @MainActor (NavigationInteractionKind) -> Void] = [:]
    private(set) var records: [Record] = []
    private var counters: [Counter: Int] = [:]
    private let capacity: Int
    private var inputMonitor: Any?
    private var inputSerial: UInt64 = 0
    private var currentInput: (serial: UInt64, started: ContinuousClock.Instant, queueDelay: Double)?

    init(capacity: Int = 4_096) { self.capacity = max(1, capacity) }

    /// Captures timing only; neither keys, characters, locations nor targets are read.
    func installInputMonitoring() {
        guard inputMonitor == nil, !ProcessInfo.processInfo.arguments.contains("--performance-audit") else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            // AppKit calls local event monitors on its main event-dispatch thread.
            MainActor.assumeIsolated { self?.captureInput(timestamp: event.timestamp) }
            return event
        }
    }

    func captureInput(timestamp: TimeInterval) {
        let delay = ProcessInfo.processInfo.systemUptime - timestamp
        guard timestamp.isFinite, timestamp > 0, delay >= 0 else { return }
        inputSerial &+= 1
        let serial = inputSerial
        currentInput = (serial, ContinuousClock.now.advanced(by: .seconds(-delay)), delay * 1_000)
        // Limit attribution to handlers running in this event turn. In particular,
        // a later refresh/task must not inherit NSApp.currentEvent's old timestamp.
        DispatchQueue.main.async { [weak self] in
            if self?.currentInput?.serial == serial { self?.currentInput = nil }
        }
    }

    @discardableResult
    func begin(_ kind: NavigationInteractionKind, destination: String? = nil) -> UInt64 {
        finish(kind, outcome: .superseded)
        nextGeneration &+= 1
        // Never allow an arbitrary label, subject, address, or query into reports.
        let safeDestination = destination.flatMap { ["mail", "calendar", "attachments"].contains($0) ? $0 : nil }
        pending[kind] = Pending(generation: nextGeneration, kind: kind, destination: safeDestination,
                                started: currentInput?.started ?? .now, token: TernSignposts.begin(kind.span),
                                timingOrigin: currentInput == nil ? .programmatic : .input,
                                inputQueueDelayMilliseconds: currentInput?.queueDelay)
        notify(kind)
        return nextGeneration
    }

    func currentGeneration(for kind: NavigationInteractionKind) -> UInt64? { pending[kind]?.generation }

    func contentReady(_ kind: NavigationInteractionKind, cacheTier: NavigationCacheTier,
                      generation: UInt64? = nil) {
        guard var current = pending[kind], generation == nil || generation == current.generation else { return }
        guard current.ready == nil else { return }
        current.ready = .now
        current.cacheTier = cacheTier
        pending[kind] = current
        notify(kind)
    }

    func isReady(_ kind: NavigationInteractionKind, generation: UInt64) -> Bool {
        guard let current = pending[kind], current.generation == generation else { return false }
        return current.ready != nil
    }

    /// Called only after the active content probe has drawn in the visible viewport.
    func didCommitVisibleContent(_ kind: NavigationInteractionKind, generation: UInt64) {
        guard isReady(kind, generation: generation) else { return }
        finish(kind, outcome: .visibleCommit)
    }

    func cancel(_ kind: NavigationInteractionKind, generation: UInt64? = nil) {
        guard generation == nil || pending[kind]?.generation == generation else { return }
        finish(kind, outcome: .cancelled)
    }

    func increment(_ counter: Counter, by amount: Int = 1) { counters[counter, default: 0] += amount }

    @discardableResult
    func observe(_ observer: @escaping @MainActor (NavigationInteractionKind) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func waitForCompletion(_ kind: NavigationInteractionKind, generation: UInt64,
                           timeout: Duration = .seconds(5)) async -> Record? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if let result = records.last(where: { $0.generation == generation }) { return result }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        if pending[kind]?.generation == generation {
            finish(kind, outcome: Task.isCancelled ? .cancelled : .timedOut)
        }
        return records.last { $0.generation == generation }
    }

    func report() -> Report {
        var groups: [String: [Double]] = [:]
        for record in records where record.outcome == .visibleCommit {
            let key = [record.kind.rawValue, record.destination, record.cacheTier?.rawValue, record.timingOrigin.rawValue]
                .compactMap { $0 }.joined(separator: ".")
            groups[key, default: []].append(record.elapsedMilliseconds)
        }
        let stages: [TernSpan] = [.readerPreparation, .readerResources, .calendarPreparation, .mailListProjection]
        let stageSummaries = Dictionary(uniqueKeysWithValues: stages.compactMap { span -> (String, Summary)? in
            guard let summary = Summary(SpanRecorder.shared.records(for: span).map { Self.milliseconds($0.duration) }) else { return nil }
            return (span.rawValue, summary)
        })
        return Report(endpoint: "input timestamp or programmatic selection to ready-content native drawing commit; GPU presentation requires Instruments",
                      records: records, summaries: groups.compactMapValues(Summary.init),
                      stageSummaries: stageSummaries,
                      counters: Dictionary(uniqueKeysWithValues: counters.map { ($0.key.rawValue, $0.value) }),
                      physicalFootprintBytes: Self.physicalFootprint())
    }

    func reset() {
        for kind in NavigationInteractionKind.allCases { finish(kind, outcome: .cancelled) }
        records.removeAll(keepingCapacity: true)
        counters.removeAll(keepingCapacity: true)
        currentInput = nil
        SpanRecorder.shared.removeAll()
    }

    private func finish(_ kind: NavigationInteractionKind, outcome: Outcome) {
        guard let current = pending.removeValue(forKey: kind) else { return }
        let ended = ContinuousClock.now
        if outcome == .visibleCommit { TernSignposts.end(current.token) }
        else { TernSignposts.cancel(current.token) }
        records.append(Record(generation: current.generation, kind: kind, destination: current.destination,
                              cacheTier: current.cacheTier, outcome: outcome,
                              timingOrigin: current.timingOrigin,
                              inputQueueDelayMilliseconds: current.inputQueueDelayMilliseconds,
                              contentReadyMilliseconds: current.ready.map { Self.milliseconds(current.started.duration(to: $0)) },
                              elapsedMilliseconds: Self.milliseconds(current.started.duration(to: ended))))
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }

    private func notify(_ kind: NavigationInteractionKind) {
        for callback in Array(observers.values) { callback(kind) }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
