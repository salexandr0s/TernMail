import AppKit

/// Holds a process activity while an account syncs or sends, so App Nap
/// doesn't slow Gmail requests from a window in the background. A send is
/// the user's own work; a pass is background work. Nothing is held while the
/// accounts are idle, so the Mac naps and sleeps as usual.
@MainActor
final class SyncActivityGuard {
    enum Work: Hashable {
        case pass(accountID: String)
        case send(accountID: String)

        var accountID: String {
            switch self {
            case .pass(let accountID), .send(let accountID): accountID
            }
        }
    }

    private(set) var work: Set<Work> = []
    private(set) var options: ProcessInfo.ActivityOptions?
    private var activity: (any NSObjectProtocol)?
    private let process: any ProcessActivities

    init(process: any ProcessActivities = ProcessInfo.processInfo) {
        self.process = process
    }

    func update(_ item: Work, isActive: Bool) {
        if isActive { work.insert(item) } else { work.remove(item) }
        apply()
    }

    /// An account stopped, so nothing of its is under way any more.
    func release(accountID: String) {
        work = work.filter { $0.accountID != accountID }
        apply()
    }

    private func apply() {
        let wanted: ProcessInfo.ActivityOptions? = if work.isEmpty {
            nil
        } else if work.contains(where: { if case .send = $0 { true } else { false } }) {
            .userInitiatedAllowingIdleSystemSleep
        } else {
            .background
        }
        guard wanted != options else { return }
        if let activity { process.endActivity(activity) }
        activity = wanted.map { process.beginActivity(options: $0, reason: "Syncing mail") }
        options = wanted
    }
}

/// `ProcessInfo`'s activity calls, behind a protocol so tests can watch them.
protocol ProcessActivities {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol
    func endActivity(_ activity: any NSObjectProtocol)
}

extension ProcessInfo: ProcessActivities {}
