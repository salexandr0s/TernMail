import Foundation
import GmailAPI
import MailOrganization
import MailStore
import MessageContent

enum OrganizationApplicationValidation {
    static func validate(_ categories: [OrganizationApplicationCategory], samples: MailOrganizationSamples) throws {
        guard !categories.isEmpty, categories.count <= OrganizationJobLimits.maximumCategories,
              !samples.messages.isEmpty, samples.messages.count <= OrganizationJobLimits.maximumMessages,
              Set(samples.messages.map(\.messageID)).count == samples.messages.count,
              Set(categories.map(\.id)).count == categories.count,
              Set(categories.map { labelKey($0.name) }).count == categories.count else {
            throw OrganizationApplicationError.invalidSelection
        }
        let available = Set(samples.messages.map(\.messageID))
        let evidence = OrganizationEvidence(messages: samples.messages.map {
            .init(id: $0.messageID, threadID: $0.threadID, sender: $0.sender, recipients: $0.recipients,
                  date: $0.date, isSent: $0.isSent, hasMailingListHeaders: $0.hasMailingListHeaders,
                  isAutomated: $0.isAutomated)
        })
        var ruleOwners = Set<String>()
        for category in categories {
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.id.isEmpty, category.id.utf8.count <= 1_024, !name.isEmpty, name.utf8.count <= 225,
                  (labelKey(name) != "action" || category.kind == .action),
                  (labelKey(name) != "waiting" || category.kind == .waiting),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  LabelRules.problem(with: name, among: []) == nil,
                  !category.messageIDs.isEmpty, category.messageIDs.count <= OrganizationJobLimits.maximumMessages,
                  Set(category.messageIDs).count == category.messageIDs.count,
                  Set(category.messageIDs).isSubset(of: available),
                  category.backfillExisting || (category.createFilter && !category.ruleSenders.isEmpty),
                  category.ruleSenders.count <= OrganizationJobLimits.maximumRuleSenders,
                  Set(category.ruleSenders.map { $0.lowercased() }).count == category.ruleSenders.count else {
                throw OrganizationApplicationError.invalidSelection
            }
            if category.kind != .topic, !category.messageIDs.allSatisfy({
                evidence.supportsState(messageID: $0, isWaiting: category.kind == .waiting)
            }) { throw OrganizationApplicationError.staleSamples }
            guard category.createFilter, !category.ruleSenders.isEmpty else { continue }
            guard category.kind == .topic, !samples.isPartial else { throw OrganizationApplicationError.unsafeRule }
            let classified = Set(category.messageIDs)
            for sender in category.ruleSenders {
                guard sender.utf8.count <= 254,
                      sender.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$"#,
                                   options: .regularExpression) != nil,
                      evidence.supportsRule(sender: sender, classifiedMessageIDs: classified),
                      ruleOwners.insert(sender.lowercased()).inserted,
                      ruleOwners.count <= OrganizationJobLimits.maximumRuleSenders else {
                    throw OrganizationApplicationError.unsafeRule
                }
            }
        }
    }

    static func existingLabels(_ categories: [OrganizationApplicationCategory], samples: MailOrganizationSamples,
                               current: [GmailLabel]) throws -> [String: GmailLabel] {
        var result: [String: GmailLabel] = [:]
        for category in categories {
            if let id = category.existingLabelID {
                guard let original = samples.existingLabels.first(where: { $0.id == id && !$0.isSystem }),
                      category.name.trimmingCharacters(in: .whitespacesAndNewlines) == original.name,
                      let live = current.first(where: { $0.id == id && !$0.isSystem }),
                      live.name == original.name else { throw OrganizationApplicationError.staleLabels }
                result[category.id] = live
            } else if let live = current.first(where: { !$0.isSystem && labelKey($0.name) == labelKey(category.name) }) {
                result[category.id] = live
            }
        }
        return result
    }

    static func validateCache(_ samples: MailOrganizationSamples, categories: [OrganizationApplicationCategory],
                               accountID: String, in tx: CacheTransaction) throws {
        let cached = try tx.messageLabelSnapshots(messageIDs: samples.messages.map(\.messageID), accountID: accountID,
                                                matchingLabelIDs: trackedLabels)
        for sample in samples.messages {
            guard let snapshot = cached[sample.messageID], snapshot.threadID == sample.threadID else {
                throw OrganizationApplicationError.staleSamples
            }
            guard snapshot.sender == sample.sender.lowercased(), snapshot.labelIDs.contains(SystemLabel.sent) == sample.isSent,
                  snapshot.labelIDs.isDisjoint(with: excludedLabels) else { throw OrganizationApplicationError.staleSamples }
        }
        let byID = Dictionary(uniqueKeysWithValues: samples.messages.map { ($0.messageID, $0) })
        let workflow = categories.filter { $0.kind != .topic }
        let threads = Set(workflow.flatMap(\.messageIDs).compactMap { byID[$0]?.threadID })
        let newer = try tx.messageLabelSnapshots(threadIDs: Array(threads), accountID: accountID, matchingLabelIDs: trackedLabels)
            .values.filter { !LocalSend.isProvisional($0.messageID) && $0.labelIDs.isDisjoint(with: excludedLabels) }
        let byThread = Dictionary(grouping: newer, by: \.threadID)
        for category in workflow {
            for id in category.messageIDs {
                guard let sample = byID[id], let date = sample.date,
                      sample.isSent == (category.kind == .waiting),
                      !(byThread[sample.threadID] ?? []).contains(where: {
                          $0.messageID != sample.messageID && $0.date >= date
                      }) else { throw OrganizationApplicationError.staleSamples }
            }
        }
    }

    static func pendingFilters(_ actions: [PendingAction]) -> [GmailFilter] {
        actions.compactMap { row in
            guard row.state == .queued || row.state == .sending else { return nil }
            switch row.settingsChange {
            case .createFilter(let filter, _): return filter
            case .replaceFilter(_, _, let replacement, _, _): return replacement
            default: return nil
            }
        }
    }

    static func filterCount(current: [GmailFilter], pending: [GmailFilter]) -> Int {
        var unique = current
        for filter in pending where !unique.contains(where: { $0.hasSameRules(as: filter) }) { unique.append(filter) }
        return unique.count
    }

    static func hasRuleConflict(_ actions: [PendingAction], labelID: String) -> Bool {
        actions.contains { row in
            guard row.state == .queued || row.state == .sending else { return false }
            switch row.settingsChange {
            case .deleteFilter(_, let previous, _):
                return previous.action.addLabelIds?.contains(labelID) == true
            case .replaceFilter(_, let previous, let replacement, _, _):
                return previous.action.addLabelIds?.contains(labelID) == true
                    || replacement.action.addLabelIds?.contains(labelID) == true
            default: return false
            }
        }
    }

    private static let excludedLabels: Set<String> = [SystemLabel.spam, SystemLabel.trash, SystemLabel.draft, "CHAT"]
    private static let trackedLabels = excludedLabels.union([SystemLabel.sent])

    private static func labelKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }
}
