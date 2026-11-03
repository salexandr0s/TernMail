import Foundation

public struct OrganizationExistingLabel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct OrganizationExistingRule: Codable, Equatable, Sendable {
    public let id: String
    public let labelIDs: [String]
    public let criteria: String
    public let actions: String

    public init(id: String, labelIDs: [String], criteria: String, actions: String) {
        self.id = id; self.labelIDs = labelIDs; self.criteria = criteria; self.actions = actions
    }
}

public struct OrganizationContext: Codable, Equatable, Sendable {
    public let labels: [OrganizationExistingLabel]
    public let rules: [OrganizationExistingRule]
    public let filterContextAvailable: Bool

    public init(labels: [OrganizationExistingLabel], rules: [OrganizationExistingRule],
                filterContextAvailable: Bool = true) {
        self.labels = labels; self.rules = rules; self.filterContextAvailable = filterContextAvailable
    }
}

public struct OrganizationAnalysisProgress: Equatable, Sendable {
    public enum Stage: String, Sendable { case discovering, consolidating, auditing, validating }
    public let stage: Stage
    public let completedBatches: Int
    public let totalBatches: Int
    public let analyzedCount: Int

    public init(stage: Stage, completedBatches: Int, totalBatches: Int, analyzedCount: Int) {
        self.stage = stage; self.completedBatches = completedBatches
        self.totalBatches = totalBatches; self.analyzedCount = analyzedCount
    }
}

/// Successful, validated responses for a single in-memory analysis job.
/// A fingerprint binds them to the sampled content, catalogue, rules and model.
public struct OrganizationAnalysisCheckpoint: Sendable {
    var fingerprint: String?
    var responses: [String: String] = [:]

    public init() {}
}

struct OrganizationJobTheme: Sendable {
    let id: String
    let name: String
    let explanation: String
    let kind: OrganizationCategory.Kind
    let existingLabelID: String?
    let messageIDs: [String]
}

struct OrganizationJobAssignment: Sendable {
    let categoryID: String
    let messageIDs: [String]
}

struct OrganizationJobRuleCandidate: Sendable {
    let sender: String
    let categoryID: String
    let messages: [OrganizationEmail]
}
