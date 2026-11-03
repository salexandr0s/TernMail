import Foundation
import Observation

@MainActor @Observable
final class FollowUpPreferences {
    static let delayRange = 1...365
    static let coverageMessage = "Checks new sent mail and up to 100 cached sent conversations per account from the last 30 days. Older conversations are not fully covered."

    var automaticRemindersEnabled: Bool {
        didSet {
            guard automaticRemindersEnabled != oldValue else { return }
            if automaticRemindersEnabled { enabledSince = now(); defaults?.set(enabledSince.timeIntervalSince1970, forKey: Key.enabledSince) }
            defaults?.set(automaticRemindersEnabled, forKey: Key.enabled)
            changed()
        }
    }
    var delayDays: Int {
        didSet {
            let bounded = min(max(delayDays, Self.delayRange.lowerBound), Self.delayRange.upperBound)
            if bounded != delayDays { delayDays = bounded }
            guard delayDays != oldValue else { return }
            defaults?.set(delayDays, forKey: Key.days)
            changed()
        }
    }
    var automaticDraftsEnabled: Bool {
        didSet {
            guard automaticDraftsEnabled != oldValue else { return }
            defaults?.set(automaticDraftsEnabled, forKey: Key.drafts)
            changed()
        }
    }
    private(set) var enabledSince: Date
    private(set) var revision = 0
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: @MainActor () -> Date

    init(defaults: UserDefaults? = .standard, now: @escaping @MainActor () -> Date = { .now }) {
        self.defaults = defaults; self.now = now
        automaticRemindersEnabled = defaults?.object(forKey: Key.enabled) == nil ? true : defaults?.bool(forKey: Key.enabled) ?? true
        let days = defaults?.object(forKey: Key.days) == nil ? 3 : defaults?.integer(forKey: Key.days) ?? 3
        delayDays = min(max(days, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        automaticDraftsEnabled = defaults?.bool(forKey: Key.drafts) ?? false
        if let timestamp = defaults?.object(forKey: Key.enabledSince) as? Double, timestamp.isFinite {
            enabledSince = Date(timeIntervalSince1970: timestamp)
        } else {
            enabledSince = now()
            defaults?.set(enabledSince.timeIntervalSince1970, forKey: Key.enabledSince)
        }
    }

    private func changed() { revision += 1; onChange?() }

    private enum Key {
        static let enabled = "followUps.automaticRemindersEnabled"
        static let days = "followUps.delayDays"
        static let drafts = "followUps.automaticDraftsEnabled"
        static let enabledSince = "followUps.enabledSince"
    }
}
