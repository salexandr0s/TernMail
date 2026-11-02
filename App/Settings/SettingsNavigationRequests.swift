import Observation

/// Other windows request a pane; the Settings window decides whether edits
/// must be discarded before changing its selection.
@MainActor @Observable
final class SettingsNavigationRequests {
    static let shared = SettingsNavigationRequests()
    private(set) var revision = 0
    private var destination: SettingsDestination?

    func request(_ destination: SettingsDestination) {
        self.destination = destination
        revision &+= 1
    }

    func takeRequest() -> SettingsDestination? {
        defer { destination = nil }
        return destination
    }
}
