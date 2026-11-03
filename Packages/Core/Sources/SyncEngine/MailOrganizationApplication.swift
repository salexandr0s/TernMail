import Foundation
import GmailAPI
import MailStore
import MailOrganization

public struct OrganizationApplicationCategory: Sendable, Equatable {
    public enum Kind: String, Sendable { case topic, action, waiting }
    public let id: String
    public let name: String
    public let kind: Kind
    public let messageIDs: [String]
    public let ruleSenders: [String]
    public let createFilter: Bool
    public let existingLabelID: String?
    public let backfillExisting: Bool

    public init(id: String, name: String, kind: Kind, messageIDs: [String],
                ruleSenders: [String], createFilter: Bool = true, existingLabelID: String? = nil,
                backfillExisting: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.messageIDs = messageIDs
        self.ruleSenders = ruleSenders
        self.createFilter = createFilter
        self.existingLabelID = existingLabelID
        self.backfillExisting = backfillExisting
    }
}

public enum OrganizationApplicationError: Error, Sendable, Equatable {
    case invalidSelection, accountMismatch, staleSamples, unsafeRule, conflictingChange, settingsPermissionRequired
    case staleLabels, staleRules, filterLimitReached
}

/// Retain this receipt while showing delivery progress. The durable queue
/// continues sending if the review closes or Tern restarts.
public struct OrganizationApplicationReceipt: Sendable {
    public let accountID: String
    public let actionIDs: [Int64]
    public let categoryCount: Int
    public let messageCount: Int
    public let filterCount: Int
    let actions: ActionReceipt
}

public struct OrganizationApplicationStatus: Sendable, Equatable {
    public let pendingCount: Int
    public let sentCount: Int
    public let failedCount: Int
    /// Removed or undone rows with no confirmed successful outcome.
    public let unconfirmedCount: Int
    public var isComplete: Bool { pendingCount == 0 && failedCount == 0 && unconfirmedCount == 0 }

    public init(pendingCount: Int, sentCount: Int, failedCount: Int, unconfirmedCount: Int) {
        self.pendingCount = pendingCount
        self.sentCount = sentCount
        self.failedCount = failedCount
        self.unconfirmedCount = unconfirmedCount
    }
}

extension SyncEngine {
    /// Atomically records the reviewed changes. Only the queue writes Gmail:
    /// selected backfills add labels, and each future filter only adds its label.
    public func applyOrganization(
        categories: [OrganizationApplicationCategory], samples: MailOrganizationSamples,
        isAuthorized: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> OrganizationApplicationReceipt {
        guard samples.accountID == accountID else { throw OrganizationApplicationError.accountMismatch }
        try OrganizationApplicationValidation.validate(categories, samples: samples)
        try await organizationApplicationAccess(isAuthorized)
        let makesFilters = categories.contains { $0.createFilter && !$0.ruleSenders.isEmpty }
        if makesFilters { try await organizationFilterPermission() }
        let serverLabels = try await gmail.labels()
        try await organizationApplicationAccess(isAuthorized)
        let existing = try OrganizationApplicationValidation.existingLabels(categories, samples: samples, current: serverLabels)
        let serverFilters: [GmailFilter]
        if makesFilters, let settings {
            try await organizationFilterPermission()
            serverFilters = try await settings.filters()
            try await organizationApplicationAccess(isAuthorized)
            try await organizationFilterPermission()
        } else { serverFilters = [] }
        try await organizationApplicationAccess(isAuthorized)
        let accountID = accountID
        let now = now()
        let hold = undoHolds
        let queued = try await write { tx in
            try OrganizationApplicationValidation.validateCache(samples, categories: categories, accountID: accountID, in: tx)
            var pending = try tx.pendingActions(accountID: accountID)
            let displayed = try tx.displayedLabels(accountID: accountID)
            let pendingRules = OrganizationApplicationValidation.pendingFilters(pending)
            var reservedCount = OrganizationApplicationValidation.filterCount(current: serverFilters, pending: pendingRules)
            var result: [PendingAction] = []
            var filterCount = 0
            for category in categories {
                let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let local = displayed.first { !$0.isSystem && $0.name.caseInsensitiveCompare(name) == .orderedSame }
                let labelID: String
                if let server = existing[category.id] {
                    guard !pending.contains(where: { row in
                        row.labelID == server.id && row.state != .sent &&
                            (row.kind == .deleteLabel || (row.kind == .updateLabel && row.labelChange?.newName != nil))
                    }) else { throw OrganizationApplicationError.conflictingChange }
                    try tx.saveLabels([Mapping.label(server, accountID: accountID)], accountID: accountID)
                    labelID = server.id
                } else if let local, let create = pending.first(where: { $0.kind == .createLabel && $0.labelID == local.id }) {
                    labelID = local.id
                    result.append(create)
                } else {
                    guard LabelRules.problem(with: name, among: serverLabels.map { Mapping.label($0, accountID: accountID) }) == nil
                    else { throw OrganizationApplicationError.invalidSelection }
                    labelID = LabelRules.temporaryID()
                    let row = try tx.enqueueLabelChange(.createLabel, labelID: labelID,
                        change: .init(newName: name), accountID: accountID, now: now,
                        notBefore: now.addingTimeInterval(hold.labels))
                    result.append(row); pending.append(row)
                }
                let ids = category.backfillExisting ? category.messageIDs.sorted() : []
                for start in stride(from: 0, to: ids.count, by: 1_000) {
                    let chunk = Array(ids[start..<min(start + 1_000, ids.count)])
                    if let row = try tx.enqueue(.modifyMessages, accountID: accountID,
                        messageIDs: chunk, add: [labelID], now: now,
                        notBefore: now.addingTimeInterval(hold.triage)) {
                        result.append(row); pending.append(row)
                    } else {
                        let selected = Set(chunk)
                        result += pending.filter {
                            $0.kind == .modifyMessages && $0.addLabelIDs.contains(labelID)
                                && !selected.isDisjoint(with: $0.messageIDs)
                        }
                    }
                }
                guard category.createFilter else { continue }
                guard !OrganizationApplicationValidation.hasRuleConflict(pending, labelID: labelID) else {
                    throw OrganizationApplicationError.conflictingChange
                }
                let coverage = OrganizationRuleCoverage(labelID: labelID, proposedSenders: category.ruleSenders,
                                                       existingFilters: serverFilters)
                if samples.filterContextAvailable {
                    let reviewed = samples.ruleCoverage(existingLabelID: category.existingLabelID,
                        labelName: category.name, proposedSenders: category.ruleSenders)
                    guard Set(reviewed.alreadyCoveredSenders).isSubset(of: Set(coverage.alreadyCoveredSenders)) else {
                        throw OrganizationApplicationError.staleRules
                    }
                }
                for sender in coverage.newSenders {
                    let filter = GmailFilter(criteria: .init(from: sender), action: .init(addLabelIds: [labelID]))
                    if let row = pending.first(where: {
                        guard $0.state == .queued || $0.state == .sending else { return false }
                        if case .createFilter(let value, _) = $0.settingsChange { return value.hasSameRules(as: filter) }
                        return false
                    }) {
                        result.append(row)
                    } else {
                        guard reservedCount < OrganizationJobLimits.maximumRuleSenders else {
                            throw OrganizationApplicationError.filterLimitReached
                        }
                        let row = try tx.enqueueSettingsChange(.createFilter(filter: filter, listedIDs: nil),
                            accountID: accountID, now: now, notBefore: now.addingTimeInterval(hold.settings))
                        result.append(row); pending.append(row); reservedCount += 1
                    }
                    filterCount += 1
                }
            }
            var seen = Set<Int64>()
            return (rows: result.filter { $0.id.map { seen.insert($0).inserted } ?? false }, filterCount: filterCount)
        }
        let receipt = register(queued.rows)
        scheduleSending()
        return OrganizationApplicationReceipt(accountID: accountID, actionIDs: queued.rows.compactMap(\.id),
            categoryCount: categories.count,
            messageCount: Set(categories.filter(\.backfillExisting).flatMap(\.messageIDs)).count,
            filterCount: queued.filterCount, actions: receipt)
    }

    public func renewOrganizationSamples(_ samples: MailOrganizationSamples,
        isAuthorized: @escaping @Sendable () async -> Bool = { true }) async throws {
        guard samples.accountID == accountID else { throw OrganizationApplicationError.accountMismatch }
        try await organizationApplicationAccess(isAuthorized)
        let ids = Set(samples.messages.map(\.threadID))
        let accountID = accountID
        let expires = now().addingTimeInterval(CacheHolds.searchLifetime)
        try await write { tx in try tx.holdSearchResults(ids, until: expires, accountID: accountID) }
        try await organizationApplicationAccess(isAuthorized)
    }

    public func organizationApplicationStatus(_ receipt: OrganizationApplicationReceipt) async throws -> OrganizationApplicationStatus {
        guard receipt.accountID == accountID else { throw OrganizationApplicationError.accountMismatch }
        let snapshots = receipt.actions.actions
        return try await cache.read { tx in
            var pending = 0, sent = 0, failed = 0, unconfirmed = 0
            for snapshot in snapshots {
                guard let id = snapshot.id else { unconfirmed += 1; continue }
                if let row = try tx.action(id: id) {
                    switch row.state {
                    case .queued, .sending: pending += 1
                    case .sent: sent += 1
                    case .failed: failed += 1
                    case .undone: unconfirmed += 1
                    }
                } else if snapshot.state == .sent {
                    sent += 1
                } else {
                    unconfirmed += 1
                }
            }
            return OrganizationApplicationStatus(pendingCount: pending, sentCount: sent,
                failedCount: failed, unconfirmedCount: unconfirmed)
        }
    }

    private func organizationApplicationAccess(_ isAuthorized: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard !isStopped, !stopRequested.withLock({ $0 }) else { throw CancellationError() }
        let authorized = await isAuthorized()
        try Task.checkCancellation()
        guard !isStopped, !stopRequested.withLock({ $0 }) else { throw CancellationError() }
        guard authorized else { throw AssistantMailError.accessChanged }
    }

    private func organizationFilterPermission() async throws {
        guard settings != nil else { throw OrganizationApplicationError.settingsPermissionRequired }
        if let accounts {
            guard let account = try await accounts.accounts().first(where: { $0.id == accountID }),
                  account.enabledFeatures.contains(AccountFeature.gmailSettings.rawValue),
                  GoogleScopes.isCovered(.gmailSettings, by: account.grantedScopes) else {
                throw OrganizationApplicationError.settingsPermissionRequired
            }
        }
    }

}
