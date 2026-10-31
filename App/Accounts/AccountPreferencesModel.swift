import Foundation
import MailStore
import Observation

/// Durable preferences stay independent of the runtime mailbox and its engine.
@MainActor @Observable
final class AccountPreferencesModel {
    static let activeProfileKey = "tern.activeMailProfile"
    private(set) var records: [AccountRecord] = []
    private(set) var preferencesByID: [String: AccountMailPreferences] = [:]
    private(set) var profiles: [MailProfile] = []
    private(set) var activeProfileID: String?
    var error: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored let store: AccountStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var refreshGeneration = UUID()

    init(store: AccountStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        activeProfileID = defaults.string(forKey: Self.activeProfileKey)
    }

    func start() async {
        guard observation == nil else { return }
        await refresh()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readFocusedProfile() }
            }
        observation = Task { [weak self, store] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    do { for try await _ in store.observeMailPreferences() { await self?.refresh() } }
                    catch { await self?.reportLoadFailure() }
                }
                group.addTask { [weak self] in
                    do { for try await _ in store.observeMailProfiles() { await self?.refresh() } }
                    catch { await self?.reportLoadFailure() }
                }
            }
        }
    }

    func stop() {
        refreshGeneration = UUID()
        observation?.cancel()
        observation = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        do {
            async let records = store.accounts()
            async let preferences = store.allMailPreferences()
            async let profiles = store.mailProfiles()
            let result = try await (records, preferences, profiles)
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            self.records = result.0
            preferencesByID = Dictionary(result.1.map { ($0.accountID, $0) }, uniquingKeysWith: { _, latest in latest })
            self.profiles = result.2.sorted { ($0.sortOrder, $0.name, $0.id) < ($1.sortOrder, $1.name, $1.id) }
            if let activeProfileID, !self.profiles.contains(where: { $0.id == activeProfileID }) { selectProfile(nil) }
            error = nil
            onChange?()
        } catch { if refreshGeneration == generation { reportLoadFailure() } }
    }

    func preferences(for accountID: String) -> AccountMailPreferences {
        preferencesByID[accountID] ?? AccountMailPreferences(accountID: accountID)
    }

    var orderedRecords: [AccountRecord] {
        records.sorted {
            let a = preferences(for: $0.id), b = preferences(for: $1.id)
            return (a.sortOrder, $0.addedAt, $0.id) < (b.sortOrder, $1.addedAt, $1.id)
        }
    }

    var visibleAccountIDs: Set<String> {
        Set(records.filter { activeProfileID == nil || preferences(for: $0.id).profileID == activeProfileID }.map(\.id))
    }

    func displayName(for account: AccountRecord) -> String {
        let nickname = preferences(for: account.id).nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname.flatMap { $0.isEmpty ? nil : $0 } ?? AccountAppearance.shortNames(records)[account.id] ?? account.email
    }

    func selectProfile(_ id: String?) {
        let selected = id.flatMap { candidate in profiles.contains(where: { $0.id == candidate }) ? candidate : nil }
        activeProfileID = selected
        defaults.set(selected, forKey: Self.activeProfileKey)
        onChange?()
    }

    /// Applies the change at once so controls follow it, then saves it. A failed
    /// save reloads the stored preferences.
    func update(_ id: String, _ change: @escaping @Sendable (inout AccountMailPreferences) -> Void) async {
        var local = preferences(for: id)
        change(&local)
        preferencesByID[id] = local
        // A refresh already under way read the old value; drop its result.
        refreshGeneration = UUID()
        do {
            _ = try await store.updateMailPreferences(accountID: id, change)
            await refresh()
        } catch {
            await refresh()
            self.error = "Couldn't save the account preference."
        }
    }

    /// Reorders accounts the way a list's `onMove` reports it and stores the result.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        var ordered = orderedRecords
        ordered.move(fromOffsets: offsets, toOffset: destination)
        do {
            for (index, record) in ordered.enumerated() where preferences(for: record.id).sortOrder != index {
                _ = try await store.updateMailPreferences(accountID: record.id) { $0.sortOrder = index }
            }
            await refresh()
        } catch { self.error = "Couldn't change the account order." }
    }

    func saveProfile(_ profile: MailProfile) async -> Bool {
        do { try await store.saveMailProfile(profile); await refresh(); return true }
        catch { self.error = "Couldn't save the profile. Check its name and notification hours."; return false }
    }

    func deleteProfile(_ profile: MailProfile) async {
        do { try await store.deleteMailProfile(id: profile.id); await refresh() }
        catch { self.error = "Couldn't delete the profile." }
    }

    private func readFocusedProfile() {
        let stored = defaults.string(forKey: Self.activeProfileKey)
        guard stored != activeProfileID else { return }
        activeProfileID = stored.flatMap { candidate in profiles.contains(where: { $0.id == candidate }) ? candidate : nil }
        onChange?()
    }

    private func reportLoadFailure() { error = "Couldn't load account preferences." }
}
