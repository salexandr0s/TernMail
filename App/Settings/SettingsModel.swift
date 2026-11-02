import Foundation
import GmailAPI
import MailStore
import Observation
import SyncEngine

/// Settings reads come from Google; all writes use the durable settings lane.
@MainActor @Observable
final class SettingsModel {
    let accountID: String
    let connection: SettingsAccountState
    /// Fields that save as the user types share one debounce per account.
    let liveApply = LiveApplyScheduler()
    private(set) var snapshot = SettingsSnapshot()
    @ObservationIgnored private var serverSnapshot = SettingsSnapshot()
    var filters: [GmailFilter] { snapshot.filters }
    private(set) var forwarding: [ForwardingAddress] = []
    var identities: [IdentityRecord] { snapshot.identities }
    var vacation: VacationSettings { snapshot.vacation }
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var hasLoaded = false
    private(set) var pendingCount = 0
    private(set) var revision = 0
    var error: String?
    var status: String?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var undoEntries: [SettingsUndo] = []

    init(accountID: String, app: AppModel) {
        self.accountID = accountID
        self.app = app
        connection = SettingsAccountState(accountID: accountID, store: app.settingsAccountStore)
    }

    var account: AccountRecord? { connection.account }
    var labels: [LabelRecord] { app?.mailbox?.account(id: accountID)?.labels ?? [] }
    var hasEditPermission: Bool {
        account.map { AccountFeature.named($0.enabledFeatures).contains(.gmailSettings) } == true
            && app?.settingsClient(for: accountID) != nil
    }
    var canEdit: Bool { hasEditPermission && !isSaving }
    var deliveryError: String? {
        guard status != nil, let notice = app?.mailbox?.notice, notice.isError else { return nil }
        return notice.message
    }

    func signatureReplyPreference() async -> Bool {
        guard let accounts = try? await app?.settingsAccountStore?.accounts() else { return false }
        return accounts.first(where: { $0.id == accountID })?.signatureOnReplies ?? false
    }

    func setSignatureOnReplies(_ enabled: Bool) async -> Bool {
        do {
            guard let _ = try await app?.settingsAccountStore?.updateAccount(id: accountID, { $0.signatureOnReplies = enabled }) else {
                error = "Couldn't save the reply signature preference."
                return false
            }
            error = nil
            return true
        } catch {
            self.error = "Couldn't save the reply signature preference."
            return false
        }
    }

    func load() async {
        guard !isLoading, let app, let client = app.settingsClient(for: accountID),
              let owner = app.mailbox?.account(id: accountID) else { return }
        let generation = UUID()
        self.generation = generation
        isLoading = true
        error = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            try await connection.refresh()
            let pending = try await pendingChanges()
            apply(pending)
            pendingCount = pending.count
            async let filters = client.filters()
            async let forwarding = client.forwardingAddresses()
            async let vacation = client.vacation()
            async let identities = client.sendAsIdentities()
            let loaded = try await (filters, forwarding, vacation, identities)
            guard !Task.isCancelled, self.generation == generation,
                  app.mailbox?.account(id: accountID) === owner else { return }
            let latestPending = try await pendingChanges()
            self.forwarding = loaded.1
            serverSnapshot = SettingsSnapshot(filters: loaded.0,
                identities: loaded.3.map { IdentityRecord($0, accountID: accountID, fetchedAt: .now) }, vacation: loaded.2)
            apply(latestPending)
            pendingCount = latestPending.count
            hasLoaded = true
            revision += 1
        } catch is CancellationError {
        } catch {
            guard self.generation == generation else { return }
            self.error = "Couldn't load Gmail settings. Check the connection and try again."
        }
    }

    /// A completed or rejected queue row triggers a fresh read. Editing forms
    /// keep their own document and are not reset while the queue waits offline.
    func watchQueue() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let changes = try? await pendingChanges() else { continue }
            let previous = pendingCount
            pendingCount = changes.count
            apply(changes)
            if previous != pendingCount {
                Task { [weak self] in await self?.load() }
                if pendingCount == 0 { status = "No pending settings changes." }
            }
        }
    }

    func saveFilter(_ filter: GmailFilter, replacing old: GmailFilter?) async -> Bool {
        await change(old == nil ? "Create Filter" : "Edit Filter") { engine in
            if let old { return try await engine.replaceFilter(old, with: filter) }
            return try await engine.createFilter(filter)
        }
    }

    func deleteFilter(_ filter: GmailFilter) async {
        _ = await change("Delete Filter") { try await $0.deleteFilter(filter) }
    }

    func saveSignature(_ html: String, previous: String, address: String) async -> Bool {
        guard identities.contains(where: { $0.address == address && $0.isPrimary }) else { return false }
        return await change("Change Signature") {
            try await $0.updateSignature(html, previousHTML: previous, for: address)
        }
    }

    func saveVacation(_ edited: VacationSettings, previous: VacationSettings) async -> Bool {
        await change("Change Vacation Responder") { try await $0.updateVacation(edited, from: previous) }
    }

    private func change(
        _ name: String, operation: (SyncEngine) async throws -> ActionReceipt?
    ) async -> Bool {
        do { try await connection.refresh() }
        catch { self.error = "Couldn't read this account's permissions."; return false }
        guard canEdit, let owner = app?.mailbox?.account(id: accountID) else {
            error = "Turn on Gmail Settings in Connections before saving changes."
            return false
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            if let receipt = try await operation(owner.engine) {
                let entry = SettingsUndo(engine: owner.engine, receipt: receipt)
                undoEntries.append(entry)
                if undoEntries.count > MailboxModel.undoLimit { undoEntries.removeFirst() }
                undoManager?.registerUndo(withTarget: entry) { [weak self] entry in
                    Task { @MainActor in
                        do {
                            try await entry.engine.undo(entry.receipt)
                            self?.status = "Change undone."
                            await self?.load()
                        } catch { self?.error = "Couldn't undo the settings change. Try again." }
                    }
                }
                undoManager?.setActionName(name)
                status = "Change queued. Gmail saves it when the account is online."
                // Read the durable rows before the network read; the fast path
                // may finish while the refresh is in flight.
                if let changes = try? await pendingChanges() {
                    apply(changes)
                    pendingCount = changes.count
                }
                Task { [weak self] in await self?.load() }
            }
            return true
        } catch {
            self.error = "Couldn't queue the change. Check the settings and try again."
            return false
        }
    }

    private func pendingChanges() async throws -> [PendingAction] {
        guard let cache = app?.cache else { return [] }
        let accountID = accountID
        return try await cache.read { tx in
            try tx.pendingActions(accountID: accountID).filter {
                $0.kind.lane == .settings && $0.state != .sent && $0.state != .undone
            }
        }
    }

    private func apply(_ actions: [PendingAction]) {
        let updated = serverSnapshot.applying(actions)
        if snapshot != updated {
            snapshot = updated
            revision += 1
        }
    }
}

@MainActor private final class SettingsUndo {
    let engine: SyncEngine
    let receipt: ActionReceipt
    init(engine: SyncEngine, receipt: ActionReceipt) { self.engine = engine; self.receipt = receipt }
}
