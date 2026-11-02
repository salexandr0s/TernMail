import Foundation
import Observation

/// Keeps setup independent of account restoration. Connecting the first
/// account must not dismiss setup or make a later launch treat it as complete.
@MainActor @Observable
final class OnboardingState {
    enum Step: String, CaseIterable {
        case welcome
        case google
        case chatGPT
        case preferences
        case ready
    }

    static let storageKey = "tern.onboarding.v1"
    private static let completedValue = "complete"

    private(set) var isResolved = false
    private(set) var isPresented = false
    var step: Step = .welcome {
        didSet {
            guard isResolved, isPresented else { return }
            defaults?.set(step.rawValue, forKey: Self.storageKey)
        }
    }
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    static func appState() -> OnboardingState {
        let arguments = ProcessInfo.processInfo.arguments
        let isolated = AssistantRuntimeEnvironment.isTestHost
            || arguments.contains("--ui-audit") || arguments.contains("--ui-audit-calendar")
        return OnboardingState(defaults: isolated ? nil : .standard)
    }

    /// Resolve only after the account store has opened successfully. The
    /// in-progress marker is saved before the first sign-in can finish.
    func resolve(hasExistingAccounts: Bool) {
        guard !isResolved else { return }
        let saved = defaults?.string(forKey: Self.storageKey)
        isResolved = true
        if saved == Self.completedValue || (saved == nil && hasExistingAccounts) {
            defaults?.set(Self.completedValue, forKey: Self.storageKey)
            return
        }

        isPresented = true
        let restored = saved.flatMap(Step.init(rawValue:)) ?? .welcome
        // An account removed between launches needs connecting again before
        // continuing with assistant or preferences setup.
        step = !hasExistingAccounts && [.chatGPT, .preferences, .ready].contains(restored)
            ? .google : restored
    }

    /// Showing the summary isn't completion; only its final action commits it.
    @discardableResult
    func finish(hasConnectedAccount: Bool) -> Bool {
        guard isResolved, isPresented, step == .ready, hasConnectedAccount else { return false }
        defaults?.set(Self.completedValue, forKey: Self.storageKey)
        isPresented = false
        return true
    }
}
