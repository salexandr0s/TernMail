import AppKit
import Foundation
import IMAPIdle
import Network
import Observation

/// Kept behind a protocol so lifecycle tests never open a socket or use a token.
protocol InboxMonitoring: Sendable {
    func signals() async -> AsyncThrowingStream<Void, any Error>
    func stop() async
    func reconnectNow() async
}

extension InboxMonitor: InboxMonitoring {}

/// Converts one account's IDLE signals into coalesced history-sync requests.
/// Polling remains active when IMAP is unavailable or its permission is off.
@MainActor
@Observable
final class InboxWatcher {
    enum State: Equatable {
        case stopped
        case connecting
        case watching
        case unavailable(String)
    }

    private(set) var state: State = .stopped
    @ObservationIgnored private let monitor: any InboxMonitoring
    @ObservationIgnored private let requestSync: @Sendable () async -> Void
    @ObservationIgnored private let observesSystemEvents: Bool
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retryWait: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var networkAvailable: Bool?
    @ObservationIgnored private var generation = 0

    init(
        monitor: any InboxMonitoring,
        observesSystemEvents: Bool = true,
        retryDelay: Duration = .seconds(30),
        requestSync: @escaping @Sendable () async -> Void
    ) {
        self.monitor = monitor
        self.observesSystemEvents = observesSystemEvents
        self.retryDelay = retryDelay
        self.requestSync = requestSync
    }

    func start() {
        guard task == nil else { return }
        generation += 1
        let current = generation
        state = .connecting
        if observesSystemEvents { observeSystemEvents() }
        task = Task { [weak self] in await self?.watch(generation: current) }
    }

    /// Invalidate callbacks before awaiting the actor or stream teardown.
    func stop() async {
        generation += 1
        let previous = task
        task = nil
        previous?.cancel()
        retryWait?.cancel()
        removeSystemObservers()
        state = .stopped
        await monitor.stop()
        await previous?.value
    }

    func reconnect() {
        guard state != .stopped else { return }
        if task == nil {
            start()
        } else if let retryWait {
            retryWait.cancel()
        } else {
            let monitor = monitor
            Task { await monitor.reconnectNow() }
        }
    }

    /// A path's first delivery describes startup, not a network restoration.
    func networkChanged(isAvailable: Bool) {
        let previous = networkAvailable
        networkAvailable = isAvailable
        if previous == false, isAvailable { reconnect() }
    }

    private func watch(generation current: Int) async {
        defer { if generation == current { task = nil } }
        while generation == current, !Task.isCancelled {
            do {
                let signals = await monitor.signals()
                for try await _ in signals {
                    guard generation == current, !Task.isCancelled else { return }
                    state = .watching
                    await requestSync()
                }
                return
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                // Never display a server response or token-provider error: it
                // may contain an address, authentication exchange or token.
                if let failure = error as? InboxMonitor.Failure {
                    switch failure {
                    case .unsupported:
                        state = .unavailable("IMAP updates aren't available for this account. Mail still checks every minute.")
                    case .authenticationFailed:
                        state = .unavailable("Google refused IMAP access. Turn Inbox Updates off and on to reconnect. Mail still checks every minute.")
                    }
                    return
                }
                state = .unavailable("Inbox Updates couldn't connect. Retrying; mail still checks every minute.")
                let delay = retryDelay
                let wait = Task<Void, Never> { try? await Task.sleep(for: delay) }
                retryWait = wait
                await withTaskCancellationHandler {
                    await wait.value
                } onCancel: {
                    wait.cancel()
                }
                retryWait = nil
                guard generation == current, !Task.isCancelled else { return }
                state = .connecting
            }
        }
    }

    private func observeSystemEvents() {
        guard pathMonitor == nil else { return }
        let paths = NWPathMonitor()
        paths.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(isAvailable: available) }
        }
        paths.start(queue: DispatchQueue(label: "dev.tern.inbox-network"))
        pathMonitor = paths
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect() }
        }
    }

    private func removeSystemObservers() {
        pathMonitor?.cancel()
        pathMonitor = nil
        networkAvailable = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}
