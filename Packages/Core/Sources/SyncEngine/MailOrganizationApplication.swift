import Foundation
import GmailAPI
import MailStore
import MessageContent

public struct OrganizationApplicationCategory: Sendable, Equatable {
    public enum Kind: String, Sendable { case topic, action, waiting }
    public let id: String
    public let name: String
    public let kind: Kind
    public let messageIDs: [String]
    public let ruleSenders: [String]
    public let createFilter: Bool

    public init(id: String, name: String, kind: Kind, messageIDs: [String],
                ruleSenders: [String], createFilter: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.messageIDs = messageIDs
        self.ruleSenders = ruleSenders
        self.createFilter = createFilter
    }
}

public enum OrganizationApplicationError: Error, Sendable, Equatable {
    case invalidSelection, accountMismatch, staleSamples, unsafeRule, conflictingChange, settingsPermissionRequired
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
    /// each message receives a user label, and each filter only adds that label.
    public func applyOrganization(
        categories: [OrganizationApplicationCategory], samples: MailOrganizationSamples,
        isAuthorized: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> OrganizationApplicationReceipt {
        guard samples.accountID == accountID else { throw OrganizationApplicationError.accountMismatch }
        try Self.validateOrganization(categories, samples: samples)
        try await organizationApplicationAccess(isAuthorized)
        let makesFilters = categories.contains { $0.createFilter && !$0.ruleSenders.isEmpty }
        if makesFilters { try await organizationFilterPermission() }
        let serverLabels = try await gmail.labels()
        try await organizationApplicationAccess(isAuthorized)
        if makesFilters { try await organizationFilterPermission() }
        try await organizationApplicationAccess(isAuthorized)
        let accountID = accountID
        let now = now()
        let hold = undoHolds
        let rows = try await write { tx in
            try Self.validateOrganizationCache(samples, categories: categories, accountID: accountID, in: tx)
            var result: [PendingAction] = []
            for category in categories {
                let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let pending = try tx.pendingActions(accountID: accountID)
                let displayed = try tx.displayedLabels(accountID: accountID)
                let server = serverLabels.first { !$0.isSystem && $0.name.lowercased() == name.lowercased() }
                let local = displayed.first { !$0.isSystem && $0.name.lowercased() == name.lowercased() }
                let labelID: String
                if let server {
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
                    result.append(try tx.enqueueLabelChange(.createLabel, labelID: labelID,
                        change: .init(newName: name), accountID: accountID, now: now,
                        notBefore: now.addingTimeInterval(hold.labels)))
                }
                if let row = try tx.enqueue(.modifyMessages, accountID: accountID,
                    messageIDs: category.messageIDs.sorted(), add: [labelID], now: now,
                    notBefore: now.addingTimeInterval(hold.triage)) {
                    result.append(row)
                } else {
                    // A second Apply still reports the first queued operation.
                    let selected = Set(category.messageIDs)
                    result += pending.filter {
                        $0.kind == .modifyMessages && $0.addLabelIDs.contains(labelID)
                            && !selected.isDisjoint(with: $0.messageIDs)
                    }
                }
                if category.createFilter {
                    for sender in category.ruleSenders.sorted() {
                        let filter = GmailFilter(criteria: .init(from: sender.lowercased()), action: .init(addLabelIds: [labelID]))
                        if let existing = try tx.pendingActions(accountID: accountID).first(where: {
                            if case .createFilter(let value, _) = $0.settingsChange { return value.hasSameRules(as: filter) }
                            return false
                        }) {
                            result.append(existing)
                        } else {
                            result.append(try tx.enqueueSettingsChange(.createFilter(filter: filter, listedIDs: nil),
                                accountID: accountID, now: now, notBefore: now.addingTimeInterval(hold.settings)))
                        }
                    }
                }
            }
            var seen = Set<Int64>()
            return result.filter { $0.id.map { seen.insert($0).inserted } ?? false }
        }
        // Register before starting senders so even a fast completed row updates
        // the review's receipt before a history pass can prune it.
        let receipt = register(rows)
        scheduleSending()
        return OrganizationApplicationReceipt(accountID: accountID, actionIDs: rows.compactMap(\.id),
            categoryCount: categories.count, messageCount: Set(categories.flatMap(\.messageIDs)).count,
            filterCount: categories.filter(\.createFilter).reduce(0) { $0 + $1.ruleSenders.count }, actions: receipt)
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

    private static func validateOrganization(_ categories: [OrganizationApplicationCategory], samples: MailOrganizationSamples) throws {
        guard !categories.isEmpty, categories.count <= 20, !samples.messages.isEmpty, samples.messages.count <= 250,
              Set(samples.messages.map(\.messageID)).count == samples.messages.count,
              Set(categories.map(\.id)).count == categories.count,
              Set(categories.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == categories.count
        else { throw OrganizationApplicationError.invalidSelection }
        let available = Set(samples.messages.map(\.messageID))
        var filterCount = 0
        for category in categories {
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // The opaque ID includes a normalized name; lowercasing can expand
            // Unicode even when the Gmail label itself fits its byte limit.
            guard !category.id.isEmpty, category.id.utf8.count <= 1_024, !name.isEmpty, name.utf8.count <= 225,
                  (name.lowercased() != "action" || category.kind == .action),
                  (name.lowercased() != "waiting" || category.kind == .waiting),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  LabelRules.problem(with: name, among: []) == nil, !category.messageIDs.isEmpty,
                  category.messageIDs.count <= 250, Set(category.messageIDs).count == category.messageIDs.count,
                  Set(category.messageIDs).isSubset(of: available), category.ruleSenders.count <= 30,
                  Set(category.ruleSenders.map { $0.lowercased() }).count == category.ruleSenders.count
            else { throw OrganizationApplicationError.invalidSelection }
            guard category.createFilter, !category.ruleSenders.isEmpty else { continue }
            guard category.kind == .topic, !samples.isPartial else { throw OrganizationApplicationError.unsafeRule }
            filterCount += category.ruleSenders.count
            guard filterCount <= 125 else { throw OrganizationApplicationError.unsafeRule }
            let classified = Set(category.messageIDs)
            for sender in category.ruleSenders {
                guard sender.utf8.count <= 254,
                      sender.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil
                else { throw OrganizationApplicationError.unsafeRule }
                let incoming = samples.messages.filter { !$0.isSent && $0.sender.lowercased() == sender.lowercased() }
                guard incoming.count >= 2, incoming.allSatisfy({ classified.contains($0.messageID) })
                else { throw OrganizationApplicationError.unsafeRule }
            }
        }
    }

    private static func validateOrganizationCache(
        _ samples: MailOrganizationSamples, categories: [OrganizationApplicationCategory],
        accountID: String, in tx: CacheTransaction
    ) throws {
        for sample in samples.messages {
            guard let message = try tx.message(id: sample.messageID, accountID: accountID), message.threadID == sample.threadID else {
                throw OrganizationApplicationError.staleSamples
            }
            let senders = EmailAddress.parseList(message.sender).filter(\.isValid)
            let sender = senders.count == 1 ? senders[0].normalized : ""
            let labels = try tx.labelIDs(ofMessages: [sample.messageID], accountID: accountID)
            guard sender == sample.sender.lowercased(), labels.contains(SystemLabel.sent) == sample.isSent,
                  labels.isDisjoint(with: [SystemLabel.spam, SystemLabel.trash, SystemLabel.draft, "CHAT"]) else {
                throw OrganizationApplicationError.staleSamples
            }
        }
        // A reply sent or synced while the review was open can make a workflow
        // classification stale. Check known mail without fetching whole threads.
        let byID = Dictionary(uniqueKeysWithValues: samples.messages.map { ($0.messageID, $0) })
        for category in categories where category.kind != .topic {
            for id in category.messageIDs {
                guard let sample = byID[id], let date = sample.date,
                      sample.isSent == (category.kind == .waiting) else { throw OrganizationApplicationError.staleSamples }
                for message in try tx.messages(threadID: sample.threadID, accountID: accountID)
                where !LocalSend.isProvisional(message.id)
                    && (message.date > date || (message.date == date && message.id < sample.messageID)) {
                    let labels = try tx.labelIDs(ofMessages: [message.id], accountID: accountID)
                    if labels.isDisjoint(with: [SystemLabel.spam, SystemLabel.trash, SystemLabel.draft, "CHAT"]) {
                        throw OrganizationApplicationError.staleSamples
                    }
                }
            }
        }
    }
}
