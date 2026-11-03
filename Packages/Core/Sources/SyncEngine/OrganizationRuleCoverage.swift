import Foundation
import GmailAPI

/// Existing rules stay in place. Additional senders receive label-only filters.
public struct OrganizationRuleCoverage: Sendable, Equatable {
    public let existingRuleCount: Int
    public let alreadyCoveredSenders: [String]
    public let newSenders: [String]
    public var newFilterCount: Int { newSenders.count }

    public init(labelID: String?, proposedSenders: [String], existingFilters: [GmailFilter]) {
        let senders = Set(proposedSenders.map { $0.lowercased() })
        let rules = labelID.map { id in existingFilters.filter { $0.action.addLabelIds?.contains(id) == true } } ?? []
        let covered = Set(rules.compactMap { filter -> String? in
            guard let labelID, filter.action.removeLabelIds?.contains(labelID) != true else { return nil }
            return Self.exactSender(in: filter.criteria)
        })
        existingRuleCount = rules.count
        alreadyCoveredSenders = senders.intersection(covered).sorted()
        newSenders = senders.subtracting(covered).sorted()
    }

    private static func exactSender(in criteria: GmailFilter.Criteria) -> String? {
        let otherText = [criteria.to, criteria.subject, criteria.query, criteria.negatedQuery]
        guard otherText.allSatisfy({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }),
              criteria.hasAttachment != true, criteria.excludeChats != true, criteria.size == nil,
              criteria.sizeComparison == nil || criteria.sizeComparison == .unspecified,
              let sender = criteria.from?.trimmingCharacters(in: .whitespacesAndNewlines),
              sender.utf8.count <= 254,
              sender.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$"#,
                           options: .regularExpression) != nil else { return nil }
        return sender.lowercased()
    }
}

extension MailOrganizationSamples {
    public func ruleCoverage(existingLabelID: String? = nil, labelName: String,
                             proposedSenders: [String]) -> OrganizationRuleCoverage {
        let name = labelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelID = existingLabelID ?? existingLabels.first {
            !$0.isSystem && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.id
        return .init(labelID: labelID, proposedSenders: proposedSenders, existingFilters: existingFilters)
    }
}
