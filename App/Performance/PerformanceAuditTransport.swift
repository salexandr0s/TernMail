#if DEBUG || TERN_PERFORMANCE
import Foundation

/// Synthetic transport controls. Never supplied to a real account or client.
actor PerformanceAuditTransport {
    static let shared = PerformanceAuditTransport()

    enum Mode: String, CaseIterable, Codable, Sendable {
        case idle, delayed, offline, activeSync
    }

    enum Endpoint: String, Codable, Sendable {
        case metadata, body, history, calendar, optionalResource
    }

    struct Statistics: Codable, Sendable {
        let mode: Mode
        let requestCounts: [String: Int]
        let completedRequests: Int
        let cancelledRequests: Int
        let offlineFailures: Int
        let selectedBodyDeliveries: Int
    }

    typealias BodyDelivery = @MainActor @Sendable (UInt64, ContinuousClock.Instant) -> Void

    private struct Selection {
        let token: UUID
        let accountID: String
        let threadID: String
        var generation: UInt64?
        var deliveredAt: ContinuousClock.Instant?
        var notified = false
    }

    private var mode: Mode = .idle
    private var epoch: UInt64 = 0
    private var requests: [Endpoint: Int] = [:]
    private var completed = 0
    private var cancelled = 0
    private var failedOffline = 0
    private var selectedDeliveries = 0
    private var selection: Selection?
    private var notification: Task<Void, Never>?
    private let onBodyAvailable: BodyDelivery
    private let bodyDelay: Duration

    init(bodyDelay: Duration = .milliseconds(500), onBodyAvailable: @escaping BodyDelivery = { generation, instant in
        NavigationPerformance.shared.requiredContentReady(.reader, generation: generation, at: instant, origin: .syntheticTransportResponse)
    }) {
        self.onBodyAvailable = onBodyAvailable
        self.bodyDelay = bodyDelay
    }

    func configure(_ mode: Mode, resetCounters: Bool = true) {
        self.mode = mode
        epoch &+= 1
        clearSelection()
        if resetCounters {
            requests = [:]
            completed = 0
            cancelled = 0
            failedOffline = 0
            selectedDeliveries = 0
        }
    }

    /// Delay only required body retrieval. Optional pictures never occupy the
    /// next selected message's delay or a serial semaphore.
    func request(_ endpoint: Endpoint) async throws -> Mode {
        let startedEpoch = epoch
        let requestedMode = mode
        requests[endpoint, default: 0] += 1
        if requestedMode == .offline {
            failedOffline += 1
            throw URLError(.notConnectedToInternet)
        }
        do {
            try Task.checkCancellation()
            if requestedMode == .delayed, endpoint == .body {
                try await Task.sleep(for: bodyDelay)
            }
            try Task.checkCancellation()
            guard startedEpoch == epoch else { throw CancellationError() }
            completed += 1
            return requestedMode
        } catch is CancellationError {
            if startedEpoch == epoch { cancelled += 1 }
            throw CancellationError()
        }
    }

    func willSelect(accountID: String, threadID: String) -> UUID {
        clearSelection()
        let token = UUID()
        selection = Selection(token: token, accountID: accountID, threadID: threadID)
        return token
    }

    func didSelect(_ token: UUID, generation: UInt64?) {
        guard selection?.token == token else { return }
        selection?.generation = generation
        notifyBodyAvailabilityIfReady()
    }

    /// Called after decoding the synthetic full response, before SyncEngine
    /// processes/persists it. The fixture response contains every required MIME
    /// byte, so this can include observation-queue time in the processing metric.
    func bodyDelivered(accountID: String, threadID: String, at instant: ContinuousClock.Instant) {
        guard selection?.accountID == accountID, selection?.threadID == threadID,
              selection?.deliveredAt == nil else { return }
        selection?.deliveredAt = instant
        notifyBodyAvailabilityIfReady()
    }

    func clearSelection() {
        notification?.cancel()
        notification = nil
        selection = nil
    }

    func waitForNotification() async { await notification?.value }

    func statistics() -> Statistics {
        Statistics(mode: mode, requestCounts: Dictionary(uniqueKeysWithValues: requests.map { ($0.key.rawValue, $0.value) }),
                   completedRequests: completed, cancelledRequests: cancelled, offlineFailures: failedOffline,
                   selectedBodyDeliveries: selectedDeliveries)
    }

    private func notifyBodyAvailabilityIfReady() {
        guard let current = selection, !current.notified,
              let generation = current.generation, let instant = current.deliveredAt else { return }
        selection?.notified = true
        selectedDeliveries += 1
        let callback = onBodyAvailable
        notification = Task { @MainActor in
            guard !Task.isCancelled else { return }
            callback(generation, instant)
        }
    }
}
#endif
