import Foundation

/// Bounded message facts used by both classification and Gmail application.
public struct OrganizationMessageEvidence: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let sender: String
    public let recipients: [String]
    public let date: Date?
    public let isSent: Bool
    public let hasMailingListHeaders: Bool
    public let isAutomated: Bool

    public init(id: String, threadID: String, sender: String, recipients: [String], date: Date?, isSent: Bool,
                hasMailingListHeaders: Bool = false, isAutomated: Bool = false) {
        self.id = id
        self.threadID = threadID
        self.sender = sender
        self.recipients = recipients
        self.date = date
        self.isSent = isSent
        self.hasMailingListHeaders = hasMailingListHeaders
        self.isAutomated = isAutomated
    }
}

public struct OrganizationSenderEvidence: Sendable, Equatable {
    public let address: String
    public let incomingCount: Int
    public let threadCount: Int
    public let mailingListCount: Int
    public let automatedCount: Int
    public let hasCorrespondence: Bool
    public let canCreateRule: Bool
}

/// Evidence is computed over the full supplied sample. Invalid or oversized
/// samples support neither workflow labels nor future sender rules.
public struct OrganizationEvidence: Sendable {
    public let latestMessageIDs: Set<String>
    public let eligibleRuleSenders: Set<String>
    public let senders: [OrganizationSenderEvidence]
    private let latestDirections: [String: Bool]
    private let incomingIDs: [String: Set<String>]

    public init(messages: [OrganizationMessageEvidence]) {
        guard messages.count <= 250, Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ !$0.id.isEmpty && !$0.threadID.isEmpty }) else {
            latestMessageIDs = []; eligibleRuleSenders = []; senders = []
            latestDirections = [:]; incomingIDs = [:]
            return
        }
        var latest: [String: Bool] = [:]
        for thread in Dictionary(grouping: messages, by: \.threadID).values {
            guard thread.allSatisfy({ $0.date?.timeIntervalSinceReferenceDate.isFinite == true }),
                  let newest = thread.compactMap(\.date).max() else { continue }
            let candidates = thread.filter { $0.date == newest }
            if candidates.count == 1, let message = candidates.first { latest[message.id] = message.isSent }
        }
        latestDirections = latest
        latestMessageIDs = Set(latest.keys)

        let sent = messages.filter(\.isSent)
        let sentRecipients = Set(sent.flatMap(\.recipients).map(Self.address))
        let sentThreads = Set(sent.map(\.threadID))
        let incoming = Dictionary(grouping: messages.filter { !$0.isSent && !Self.address($0.sender).isEmpty },
                                  by: { Self.address($0.sender) })
        var profiles: [OrganizationSenderEvidence] = []
        var ids: [String: Set<String>] = [:]
        for (address, messages) in incoming {
            let threads = Set(messages.map(\.threadID))
            let correspondence = sentRecipients.contains(address) || !threads.isDisjoint(with: sentThreads)
            let eligible = messages.count >= 2 && threads.count >= 2 && !correspondence
                && messages.allSatisfy { $0.hasMailingListHeaders || $0.isAutomated }
            profiles.append(.init(address: address, incomingCount: messages.count, threadCount: threads.count,
                mailingListCount: messages.filter(\.hasMailingListHeaders).count,
                automatedCount: messages.filter(\.isAutomated).count,
                hasCorrespondence: correspondence, canCreateRule: eligible))
            ids[address] = Set(messages.map(\.id))
        }
        senders = profiles.sorted {
            $0.incomingCount == $1.incomingCount ? $0.address < $1.address : $0.incomingCount > $1.incomingCount
        }
        eligibleRuleSenders = Set(profiles.filter(\.canCreateRule).map(\.address))
        incomingIDs = ids
    }

    /// Workflow state requires one dated latest message and the expected
    /// direction. Header hints do not establish whether a response is needed.
    public func supportsState(messageID: String, isWaiting: Bool) -> Bool {
        latestDirections[messageID] == isWaiting
    }

    public func supportsRule(sender: String, classifiedMessageIDs: some Sequence<String>) -> Bool {
        let address = Self.address(sender)
        guard eligibleRuleSenders.contains(address), let incoming = incomingIDs[address] else { return false }
        return incoming.isSubset(of: Set(classifiedMessageIDs))
    }

    private static func address(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
