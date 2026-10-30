import Foundation
import GmailAPI
import MailStore

/// The Gmail settings calls the settings lane makes. `GmailClient` has them
/// all, and tests pass their own.
public protocol SettingsService: Sendable {
    func filters() async throws -> [GmailFilter]
    func createFilter(criteria: GmailFilter.Criteria, action: GmailFilter.Action) async throws -> GmailFilter
    /// A filter that's already gone counts as deleted.
    func deleteFilter(id: String) async throws
    func vacation() async throws -> VacationSettings
    func updateVacation(_ settings: VacationSettings) async throws -> VacationSettings
    func updateSignature(sendAsEmail: String, signature: String) async throws -> SendAsIdentity
}

extension GmailClient: SettingsService {}

extension SyncEngine {
    // MARK: Queuing

    /// Queues a new filter after the undo hold. Undo deletes it, unless Gmail
    /// already had a filter with the same rules: Tern uses that one, and
    /// undo leaves it.
    public func createFilter(_ filter: GmailFilter) async throws -> ActionReceipt {
        try await queueSettingsChange(.createFilter(filter: filter, listedIDs: nil))
    }

    /// Queues the deletion of a filter Gmail listed. Undo creates it again.
    public func deleteFilter(_ filter: GmailFilter) async throws -> ActionReceipt {
        guard let id = filter.id else { throw GmailError.invalidRequest("Filter ID") }
        return try await queueSettingsChange(.deleteFilter(id: id, filter: filter))
    }

    /// Queues an edit of a filter Gmail listed. Gmail can't edit a filter, so
    /// the row creates the new one, then deletes the old. Nil when the rules
    /// stay the same.
    public func replaceFilter(_ old: GmailFilter, with new: GmailFilter) async throws -> ActionReceipt? {
        guard let id = old.id else { throw GmailError.invalidRequest("Filter ID") }
        guard !old.hasSameRules(as: new) else { return nil }
        return try await queueSettingsChange(.replaceFilter(oldID: id, old: old, new: new, listedIDs: nil, newID: nil))
    }

    /// Queues the fields `edited` changes from `shown`, the settings the pane
    /// fetched. When the row runs, Gmail keeps its own value of every other
    /// field, even one changed elsewhere since. Nil when nothing changed.
    ///
    /// - Throws: `GmailError.invalidRequest` when `edited` breaks Gmail's rules.
    public func updateVacation(_ edited: VacationSettings, from shown: VacationSettings) async throws -> ActionReceipt? {
        try edited.validate()
        let fields = edited.changedFields(from: shown)
        guard !fields.isEmpty else { return nil }
        return try await queueSettingsChange(.vacation(fields: fields, new: edited, previous: shown))
    }

    /// Queues `html` as the signature of `address`. Nil when it stays the same.
    public func updateSignature(_ html: String, previousHTML: String, for address: String) async throws -> ActionReceipt? {
        guard html != previousHTML else { return nil }
        return try await queueSettingsChange(.signature(address: address, html: html, previousHTML: previousHTML))
    }

    private func queueSettingsChange(_ change: PendingAction.SettingsChange) async throws -> ActionReceipt {
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let row = try await write { tx in
            try tx.enqueueSettingsChange(change, accountID: accountID, now: now, notBefore: notBefore)
        }
        scheduleSending()
        return register([row])
    }

    // MARK: Undo

    /// Queues the reverse of a settings row with no hold. Filters are found
    /// by content outside the IDs Gmail listed before the row's first
    /// attempt, never by the ID a create returned, which may belong to a
    /// filter the user already had. A create or replace that never stored
    /// its list never reached Gmail, so it has nothing to reverse.
    static func enqueueSettingsInverse(of action: PendingAction, accountID: String, now: Date, in tx: CacheTransaction) throws {
        let inverse: PendingAction.SettingsChange? = switch action.settingsChange {
        case .createFilter(let filter, let listedIDs?):
            .deleteFilter(id: nil, filter: filter, listedIDs: listedIDs)
        case .deleteFilter(_, let filter, _):
            .createFilter(filter: filter, listedIDs: nil)
        case .replaceFilter(_, let old, let new, let listedIDs?, _):
            .replaceFilter(oldID: nil, old: new, new: old, listedIDs: listedIDs, newID: nil)
        case .vacation(let fields, let new, let previous):
            .vacation(fields: fields, new: previous, previous: new)
        case .signature(let address, let html, let previousHTML):
            .signature(address: address, html: previousHTML, previousHTML: html)
        case .createFilter, .replaceFilter, nil:
            nil
        }
        guard let inverse else { return }
        _ = try tx.enqueueSettingsChange(inverse, accountID: accountID, now: now, notBefore: now)
    }

    // MARK: Sending

    /// Sends the settings rows whose hold or backoff has passed, one at a
    /// time, and returns how many it claimed.
    @discardableResult
    func sendDueSettings() async -> Int {
        guard let settings, await settingsAreEnabled() else { return 0 }
        let accountID = accountID
        let now = now()
        guard let due = try? await write({ tx in try tx.claimDueActions(accountID: accountID, now: now, lane: .settings) }) else {
            return 0
        }
        for row in due { await sendSettingsChange(row, with: settings) }
        return due.count
    }

    private func sendSettingsChange(_ claimed: PendingAction, with settings: any SettingsService) async {
        guard !isStopped, !Task.isCancelled, let id = claimed.id else { return }
        // An undo may have come in while an earlier row was out.
        let current = try? await cache.read { tx in try tx.action(id: id) }
        guard var row = current ?? nil, row.state == .sending else {
            _ = try? await write { tx in try tx.deleteActionIfUndone(id: id) }
            return
        }
        // Each row checks current consent just before beginning. A replace
        // already in progress finishes its create/delete pair as one change.
        guard await settingsAreEnabled() else {
            _ = try? await write { tx in
                guard var stored = try tx.action(id: id), stored.state == .sending else { return }
                stored.state = .queued
                stored.attempts = max(0, stored.attempts - 1)
                try tx.updateAction(stored)
            }
            return
        }
        do {
            switch row.settingsChange {
            case .createFilter(let filter, let listedIDs):
                let listed = try await settings.filters()
                if listedIDs == nil {
                    guard let recorded = try await record(.createFilter(filter: filter, listedIDs: Self.ids(of: listed)), in: row) else { return }
                    row = recorded
                }
                _ = try await createOrAdopt(filter, listed: listed, except: nil, with: settings)
            case .deleteFilter(let filterID, let filter, let listedIDs):
                if let filterID {
                    try await settings.deleteFilter(id: filterID)
                } else if let target = Self.unlistedMatch(for: filter, in: try await settings.filters(), outside: listedIDs, except: nil) {
                    try await settings.deleteFilter(id: target)
                }
            case .replaceFilter(let oldID, let old, let new, var listedIDs, var newID):
                let listed = try await settings.filters()
                if listedIDs == nil {
                    listedIDs = Self.ids(of: listed)
                    let change = PendingAction.SettingsChange.replaceFilter(
                        oldID: oldID, old: old, new: new, listedIDs: listedIDs, newID: nil
                    )
                    guard let recorded = try await record(change, in: row) else { return }
                    row = recorded
                }
                if newID == nil {
                    let created = try await createOrAdopt(new, listed: listed, except: oldID, with: settings)
                    let change = PendingAction.SettingsChange.replaceFilter(
                        oldID: oldID, old: old, new: new, listedIDs: listedIDs, newID: created
                    )
                    guard let recorded = try await record(change, in: row) else { return }
                    row = recorded
                    newID = created
                }
                if let target = oldID ?? Self.unlistedMatch(for: old, in: listed, outside: listedIDs, except: newID) {
                    try await settings.deleteFilter(id: target)
                }
            case .vacation(let fields, let new, _):
                let merged = try await settings.vacation().applying(fields, from: new)
                try merged.validate()
                _ = try await settings.updateVacation(merged)
            case .signature(let address, let html, _):
                let identity = try await settings.updateSignature(sendAsEmail: address, signature: html)
                // Compose reads signatures from the config store. If this
                // write fails, the next identity refresh corrects it.
                try? await accounts?.setSignature(identity.signature, address: address, accountID: accountID)
            case nil:
                return await refuseSettingsChange(row, error: GmailError.invalidRequest("Settings row"))
            }
            await finish(row, outcome: .sent)
        } catch {
            if case .retry(let reason) = Self.outcome(for: error) {
                await finish(row, outcome: .retry(reason))
            } else {
                await refuseSettingsChange(row, error: error)
            }
        }
    }

    private func settingsAreEnabled() async -> Bool {
        guard let accounts else { return true }
        guard let stored = try? await accounts.accounts().first(where: { $0.id == accountID }) else { return false }
        return stored.enabledFeatures.contains(AccountFeature.gmailSettings.rawValue)
            && GoogleScopes.isCovered(.gmailSettings, by: stored.grantedScopes)
    }

    /// Writes what the row has learned into its payload, before the next
    /// call depends on it. Nil when the row was undone meanwhile: it is
    /// deleted, and the inverse that undo queued does the rest.
    private func record(_ change: PendingAction.SettingsChange, in row: PendingAction) async throws -> PendingAction? {
        guard let id = row.id else { return nil }
        let recorded = try await write { tx -> PendingAction? in
            guard var stored = try tx.action(id: id), stored.state == .sending else {
                try tx.deleteActionIfUndone(id: id)
                return nil
            }
            stored.settingsChange = change
            try tx.updateAction(stored)
            return stored
        }
        if let recorded { undoReceipts[id]?.value?.update(recorded) }
        return recorded
    }

    /// Returns the ID of a filter with `filter`'s rules, creating one only
    /// when Gmail has none: an attempt Tern never heard back from may have
    /// created it, or the user had it already. Gmail answers 400 for a
    /// filter that exists, so a 400 gets the same check before it counts.
    private func createOrAdopt(
        _ filter: GmailFilter, listed: [GmailFilter], except excludedID: String?, with settings: any SettingsService
    ) async throws -> String {
        func match(in filters: [GmailFilter]) -> String? {
            filters.first { $0.id != nil && $0.id != excludedID && $0.hasSameRules(as: filter) }?.id
        }
        if let existing = match(in: listed) { return existing }
        do {
            let created = try await settings.createFilter(criteria: filter.criteria, action: filter.action)
            guard let id = created.id else { throw GmailError.decoding("GmailFilter.id") }
            return id
        } catch GmailError.http(status: 400, reason: let reason) {
            if let existing = match(in: try await settings.filters()) { return existing }
            throw GmailError.http(status: 400, reason: reason)
        }
    }

    private static func ids(of filters: [GmailFilter]) -> [String] {
        filters.compactMap(\.id)
    }

    /// A filter with `filter`'s rules that Gmail didn't list before the
    /// row's first attempt, so a Tern create made it. Nil without a list.
    private static func unlistedMatch(
        for filter: GmailFilter, in filters: [GmailFilter], outside listedIDs: [String]?, except excludedID: String?
    ) -> String? {
        guard let listedIDs else { return nil }
        return filters.first { candidate in
            guard let id = candidate.id else { return false }
            return id != excludedID && !listedIDs.contains(id) && candidate.hasSameRules(as: filter)
        }?.id
    }

    /// Gmail refused the row for good, so it leaves the queue and its undo
    /// is gone. An edit whose new filter Gmail already has queues its
    /// inverse, so Gmail ends with the old filter alone. Undo rows carry no
    /// old ID, so a refused undo queues nothing more.
    private func refuseSettingsChange(_ row: PendingAction, error: any Error) async {
        guard let id = row.id else { return }
        let accountID = accountID
        let now = now()
        let reported = try? await write { [row] tx -> Bool in
            if try tx.deleteActionIfUndone(id: id) { return false }
            try tx.deleteAction(id: id)
            if case .replaceFilter(_?, _, _, _, _?) = row.settingsChange {
                try Self.enqueueSettingsInverse(of: row, accountID: accountID, now: now, in: tx)
            }
            return true
        }
        guard reported == true else { return }
        unavailableUndoIDs.insert(id)
        continuation.yield(.actionFailed(Self.refusalMessage(for: row.kind, error: error)))
    }

    static func refusalMessage(for kind: PendingAction.Kind, error: any Error) -> String {
        if (error as? GmailError)?.isMissingScope == true {
            return "Gmail didn't save the change because Tern can't edit this account's settings. Turn on Gmail Settings for the account, then make the change again."
        }
        return switch kind {
        case .createFilter: "Gmail didn't create the filter."
        case .deleteFilter: "Gmail didn't delete the filter."
        case .replaceFilter: "Gmail didn't save the filter change, so the filter stays as it was."
        case .updateVacation: "Gmail didn't save the vacation responder."
        case .updateSignature: "Gmail didn't save the signature."
        default: "Gmail didn't accept a settings change."
        }
    }
}

extension VacationSettings {
    /// The fields that differ from `previous`.
    func changedFields(from previous: VacationSettings) -> Set<PendingAction.VacationField> {
        Set(PendingAction.VacationField.allCases.filter { field in
            switch field {
            case .enableAutoReply: enableAutoReply != previous.enableAutoReply
            case .subject: responseSubject != previous.responseSubject
            case .body: responseBodyPlainText != previous.responseBodyPlainText || responseBodyHtml != previous.responseBodyHtml
            case .restrictToContacts: restrictToContacts != previous.restrictToContacts
            case .restrictToDomain: restrictToDomain != previous.restrictToDomain
            case .startTime: startTime != previous.startTime
            case .endTime: endTime != previous.endTime
            }
        })
    }

    /// These settings with `fields` taken from `other`.
    func applying(_ fields: Set<PendingAction.VacationField>, from other: VacationSettings) -> VacationSettings {
        var result = self
        for field in fields {
            switch field {
            case .enableAutoReply: result.enableAutoReply = other.enableAutoReply
            case .subject: result.responseSubject = other.responseSubject
            case .body:
                result.responseBodyPlainText = other.responseBodyPlainText
                result.responseBodyHtml = other.responseBodyHtml
            case .restrictToContacts: result.restrictToContacts = other.restrictToContacts
            case .restrictToDomain: result.restrictToDomain = other.restrictToDomain
            case .startTime: result.startTime = other.startTime
            case .endTime: result.endTime = other.endTime
            }
        }
        return result
    }
}
