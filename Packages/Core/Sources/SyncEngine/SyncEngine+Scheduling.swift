import Foundation

/// What the user is doing with the app, which sets how often the engine
/// checks for mail when nothing has reported a change.
public enum SyncActivity: Sendable, Equatable {
    /// The app is in front.
    case active
    /// The app is open behind another.
    case inactive
    /// The Mac is asleep, or the app has been told to hold off.
    case suspended
}

/// Why a pass was asked for.
public enum SyncReason: Sendable, Equatable {
    /// The timer ran out.
    case poll
    /// IMAP reported a change in the Inbox.
    case inboxSignal
    /// The app came to the front.
    case activation
    /// Check for New Mail, or Try Again after a failure.
    case manual
    /// A queued change reached Gmail; the pass brings back its record.
    case afterAction
}

/// When the engine checks for mail on its own.
public enum SyncSchedule {
    /// How often to check while the app is in front and IMAP isn't watching.
    public static let activeInterval: Duration = .seconds(15)
    /// How often to check while the app is open behind another window.
    public static let inactiveInterval: Duration = .seconds(60)
    /// How often to check while IMAP reports Inbox changes as they happen.
    /// A pass still catches what IDLE doesn't report: other labels, drafts
    /// and changes made elsewhere.
    public static let pushInterval: Duration = .seconds(300)
    /// A pass that ran this recently satisfies an activation request.
    public static let activationThrottle: TimeInterval = 5
    /// How long a pass after a delivered change waits for the next one, so a
    /// run of archives costs one pass.
    public static let afterActionDebounce: Duration = .milliseconds(500)
    /// An Inbox signal can arrive before `history.list` shows the change. A
    /// signalled pass that finds nothing runs again after each of these.
    public static let inboxSignalRetries: [Duration] = [.seconds(1), .seconds(3)]
    /// A suspended engine re-reads its activity this often, in case the
    /// wake notification was missed.
    public static let suspendedCheck: Duration = .seconds(60 * 60)

    /// How long to wait between passes, or nil to wait for an event.
    public static func pollInterval(activity: SyncActivity, pushAvailable: Bool) -> Duration? {
        switch activity {
        case .suspended: nil
        case .active, .inactive: pushAvailable ? pushInterval : (activity == .active ? activeInterval : inactiveInterval)
        }
    }
}

extension SyncEngine {
    /// Checks for mail on `SyncSchedule`'s interval, counted from the end of
    /// the last pass whatever asked for it, until `stop()`. A suspended
    /// engine waits for `setActivity(_:)`.
    func runPolling() async {
        while !Task.isCancelled, !isStopped {
            guard let interval = SyncSchedule.pollInterval(activity: activity, pushAvailable: pushAvailable) else {
                _ = await sleep(SyncSchedule.suspendedCheck, as: .poll)
                continue
            }
            // Cut short by an activity change or a pass's end, so the wait starts over.
            guard await sleep(interval, as: .poll) else { continue }
            requestSync(reason: .poll)
            await requestedPasses?.value
        }
    }

    /// Serves the requests `requestSync(reason:)` queued, one pass at a time,
    /// with the retries of the most insistent one. A request that arrives
    /// while a pass runs gets a pass of its own afterward, since the running
    /// one may have started too early to see what it reports.
    func runRequestedPasses() async {
        defer { requestedPasses = nil }
        var retries: ArraySlice<Duration> = []
        var retryDue = false
        while !isStopped {
            await waitForPassToEnd()
            if let requested = pendingRetries {
                pendingRetries = nil
                retries = requested[...]
            } else if !retryDue {
                return
            }
            retryDue = false
            let changed = await reportingErrors { try await joinOrStartPass() }
            if pendingRetries != nil { continue }
            guard changed == false, let delay = retries.first else { return }
            retries = retries.dropFirst()
            // A request during the wait is served by the next pass, with its own retries.
            guard await sleep(delay, as: .retry) || pendingRetries != nil else { return }
            retryDue = true
        }
    }

    /// Asks for a pass once the changes stop coming for half a second.
    func runAfterActionDebounce() async {
        defer { afterActionTask = nil }
        // A further change during the wait starts it over.
        while !(await sleep(SyncSchedule.afterActionDebounce, as: .afterAction)) {
            if isStopped { return }
        }
        requestPass(retries: [])
    }

    /// Sleeps `duration` unless `wake(_:)` cuts it short or the engine stops.
    /// Returns whether it slept to the end.
    func sleep(_ duration: Duration, as sleeper: Sleeper) async -> Bool {
        let sleep = self.sleep
        let task = Task<Bool, Never> {
            do { try await sleep(duration) } catch { return false }
            return true
        }
        sleepers[sleeper] = task
        defer { sleepers[sleeper] = nil }
        if isStopped { task.cancel() }
        return await task.value
    }

    func wake(_ sleeper: Sleeper) {
        sleepers[sleeper]?.cancel()
    }

    /// The loops that sleep on the engine's clock and what wakes each.
    enum Sleeper: Hashable {
        /// `runPolling()`, woken by an activity or push change, a pass's end and `stop()`.
        case poll
        /// A retry wait in `runRequestedPasses()`, woken by a new request and by `stop()`.
        case retry
        /// `runAfterActionDebounce()`, woken by a further change and by `stop()`.
        case afterAction
    }
}
