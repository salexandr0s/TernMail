import CryptoKit
import Foundation
import MailOrganization

/// Discovers a mailbox taxonomy, reconciles the existing catalogue, and audits
/// every sampled message before proposing reviewed label and sender-rule changes.
public struct MailOrganizationJobAnalyzer: Sendable {
    private let provider: any AIProvider

    public init(provider: any AIProvider) { self.provider = provider }

    public func analyze(messages: [OrganizationEmail], context: OrganizationContext, model: String,
                        checkpoint: OrganizationAnalysisCheckpoint? = nil,
                        progress: @escaping @Sendable (OrganizationAnalysisProgress) async -> Void = { _ in },
                        didCheckpoint: @escaping @Sendable (OrganizationAnalysisCheckpoint) async -> Void = { _ in }) async throws -> OrganizationPlan {
        try Task.checkCancellation()
        let messages = try OrganizationJobValidation.prepare(messages, context: context, model: model)
        let fingerprint = try Self.fingerprint(messages, context: context, model: model)
        var saved = checkpoint ?? OrganizationAnalysisCheckpoint()
        guard saved.fingerprint == nil && saved.responses.isEmpty || saved.fingerprint == fingerprint else {
            throw MailOrganizationError.invalidInput
        }
        saved.fingerprint = fingerprint
        guard !messages.isEmpty else { return .init(categories: [], analyzedCount: 0) }
        let batches = Self.chunks(messages, size: OrganizationJobLimits.analysisBatchSize)
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let order = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
        let labels = Dictionary(uniqueKeysWithValues: context.labels.map { ($0.id, $0) })
        let evidence = OrganizationEvidence(messages: messages.map(\.evidence))
        let senders = Dictionary(uniqueKeysWithValues: evidence.senders.map { ($0.address, $0) })
        var themes: [OrganizationJobTheme] = []
        var processed = 0
        for (index, batch) in batches.enumerated() {
            try await report(.discovering, done: index, total: batches.count, count: processed, progress: progress)
            let request = try OrganizationJobRequests.discovery(batch: batch, evidence: evidence, senders: senders, model: model)
            let found = try await response(request, saved: &saved, didCheckpoint: didCheckpoint) {
                try OrganizationJobValidation.discovery($0, batch: batch, namespace: "discovery:\(index)")
            }
            themes.append(contentsOf: found)
            processed += batch.count
            try await report(.discovering, done: index + 1, total: batches.count, count: processed, progress: progress)
        }
        guard !themes.isEmpty else {
            try await report(.validating, done: 1, total: 1, count: messages.count, progress: progress)
            return .init(categories: [], analyzedCount: messages.count)
        }

        let catalogue = OrganizationJobRequests.catalogue(context)
        try await report(.consolidating, done: 0, total: catalogue.count + 2,
                         count: messages.count, progress: progress)
        var level = 0, consolidated = 0
        while themes.count > 80 {
            let groups = Self.chunks(themes, size: 80)
            var next: [OrganizationJobTheme] = []
            for (index, group) in groups.enumerated() {
                try await report(.consolidating, done: consolidated, total: consolidated + groups.count - index + catalogue.count + 2,
                                 count: messages.count, progress: progress)
                let merged = try await consolidate(group, catalogue: [], context: context, byID: byID, labels: labels,
                    order: order, namespace: "merge:\(level):\(index)", model: model, saved: &saved, didCheckpoint: didCheckpoint)
                next.append(contentsOf: merged); consolidated += 1
            }
            themes = next; level += 1
        }
        themes = try await consolidate(themes, catalogue: [], context: context, byID: byID, labels: labels,
            order: order, namespace: "taxonomy", model: model, saved: &saved, didCheckpoint: didCheckpoint)
        consolidated += 1
        for (index, partition) in catalogue.enumerated() {
            try await report(.consolidating, done: consolidated, total: consolidated + catalogue.count - index + 1,
                             count: messages.count, progress: progress)
            themes = try await consolidate(themes, catalogue: partition, context: context, byID: byID, labels: labels,
                order: order, namespace: "catalogue:\(index)", model: model, saved: &saved, didCheckpoint: didCheckpoint)
            consolidated += 1
        }
        // A final semantic pass checks the taxonomy after every catalogue partition.
        themes = try await consolidate(themes, catalogue: [], context: context, byID: byID, labels: labels,
            order: order, namespace: "final", model: model, saved: &saved, didCheckpoint: didCheckpoint)
        try await report(.consolidating, done: consolidated + 1, total: consolidated + 1,
                         count: messages.count, progress: progress)

        var assignments: [String: Set<String>] = [:]
        processed = 0
        for (index, batch) in batches.enumerated() {
            try await report(.auditing, done: index, total: batches.count, count: processed, progress: progress)
            let request = try OrganizationJobRequests.audit(batch: batch, taxonomy: themes, evidence: evidence, senders: senders, model: model)
            let reviewed = try await response(request, saved: &saved, didCheckpoint: didCheckpoint) {
                try OrganizationJobValidation.audit($0, batch: batch, taxonomy: themes)
            }
            for item in reviewed { assignments[item.categoryID, default: []].formUnion(item.messageIDs) }
            processed += batch.count
            try await report(.auditing, done: index + 1, total: batches.count, count: processed, progress: progress)
        }
        themes = Self.validatedThemes(themes, assignments: assignments, messages: messages, byID: byID, evidence: evidence)
        let candidates = context.filterContextAvailable ? Self.ruleCandidates(themes, messages: messages, evidence: evidence) : []
        let ruleBatches = Self.chunks(candidates, size: 50)
        var approved = Set<String>()
        for (index, batch) in ruleBatches.enumerated() {
            try await report(.validating, done: index, total: ruleBatches.count, count: messages.count, progress: progress)
            let request = try OrganizationJobRequests.rules(candidates: batch, taxonomy: themes, model: model)
            let addresses = try await response(request, saved: &saved, didCheckpoint: didCheckpoint) {
                try OrganizationJobValidation.rules($0, candidates: batch)
            }
            approved.formUnion(addresses)
            try await report(.validating, done: index + 1, total: ruleBatches.count, count: messages.count, progress: progress)
        }
        let rules = Dictionary(grouping: candidates.filter { approved.contains($0.sender) }, by: \.categoryID)
        let categories = themes.map { theme in
            OrganizationCategory(id: theme.id, name: theme.name, explanation: theme.explanation, kind: theme.kind,
                messageIDs: theme.messageIDs, ruleSenders: (rules[theme.id] ?? []).map(\.sender).sorted(), existingLabelID: theme.existingLabelID)
        }
        try await report(.validating, done: max(1, ruleBatches.count), total: max(1, ruleBatches.count), count: messages.count, progress: progress)
        return OrganizationPlan(categories: categories, analyzedCount: messages.count)
    }

    private func consolidate(_ sources: [OrganizationJobTheme], catalogue: [AIJSON], context: OrganizationContext,
                             byID: [String: OrganizationEmail], labels: [String: OrganizationExistingLabel], order: [String: Int],
                             namespace: String, model: String, saved: inout OrganizationAnalysisCheckpoint,
                             didCheckpoint: @escaping @Sendable (OrganizationAnalysisCheckpoint) async -> Void) async throws -> [OrganizationJobTheme] {
        let request = try OrganizationJobRequests.consolidate(themes: sources, catalogue: catalogue, existingLabels: labels,
            messages: byID, model: model, cataloguePass: !catalogue.isEmpty, filterContextAvailable: context.filterContextAvailable)
        let suppliedLabels = catalogue.flatMap { record -> [String] in
            if record["type"] == .string("label"), let id = record["id"]?.stringValue { return [id] }
            return record["labels"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        }
        let available = Set(sources.compactMap(\.existingLabelID) + suppliedLabels)
        return try await response(request, saved: &saved, didCheckpoint: didCheckpoint) {
            try OrganizationJobValidation.consolidation($0, sources: sources, context: context,
                availableLabelIDs: available, order: order, namespace: namespace)
        }
    }

    private func response<Value>(_ request: AIRequest, saved: inout OrganizationAnalysisCheckpoint,
                                  didCheckpoint: @escaping @Sendable (OrganizationAnalysisCheckpoint) async -> Void,
                                  decode: (String) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let body = try AIJSON.decode(try ChatGPTProvider.requestBody(request))
        let key = Self.hash(try OrganizationJobRequests.canonical(body))
        if let text = saved.responses[key] { return try decode(text) }
        var completion: AIResponse?, bytes = 0
        for try await event in provider.respond(request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let text):
                guard completion == nil else { throw MailOrganizationError.invalidResponse }
                guard text.utf8.count <= MailOrganizationAnalyzer.maximumResponseBytes - bytes else { throw MailOrganizationError.responseLimit }
                bytes += text.utf8.count
            case .completed(let response):
                guard completion == nil, response.toolCalls.isEmpty,
                      response.output.allSatisfy({ ["message", "reasoning"].contains($0["type"]?.stringValue ?? "") }) else {
                    throw MailOrganizationError.invalidResponse
                }
                guard response.text.utf8.count <= MailOrganizationAnalyzer.maximumResponseBytes else { throw MailOrganizationError.responseLimit }
                completion = response
            }
        }
        try Task.checkCancellation()
        guard let completion else { throw MailOrganizationError.interrupted }
        let value = try decode(completion.text)
        try Task.checkCancellation()
        saved.responses[key] = completion.text
        await didCheckpoint(saved)
        try Task.checkCancellation()
        return value
    }

    private static func validatedThemes(_ themes: [OrganizationJobTheme], assignments: [String: Set<String>],
                                        messages: [OrganizationEmail], byID: [String: OrganizationEmail],
                                        evidence: OrganizationEvidence) -> [OrganizationJobTheme] {
        themes.compactMap { theme in
            var ids = assignments[theme.id, default: []]
            if theme.kind == .topic {
                if theme.existingLabelID == nil && Set(ids.compactMap { byID[$0]?.threadID }).count < 2 { return nil }
            } else {
                ids = ids.filter { evidence.supportsState(messageID: $0, isWaiting: theme.kind == .waiting) }
            }
            guard !ids.isEmpty else { return nil }
            return .init(id: theme.id, name: theme.name, explanation: theme.explanation, kind: theme.kind,
                         existingLabelID: theme.existingLabelID, messageIDs: messages.filter { ids.contains($0.id) }.map(\.id))
        }
    }

    private static func ruleCandidates(_ themes: [OrganizationJobTheme], messages: [OrganizationEmail],
                                        evidence: OrganizationEvidence) -> [OrganizationJobRuleCandidate] {
        let incoming = Dictionary(grouping: messages.filter { !$0.isSent }, by: { $0.sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let owners = Dictionary(uniqueKeysWithValues: themes.filter { $0.kind == .topic }.flatMap { theme in theme.messageIDs.map { ($0, theme.id) } })
        var result: [OrganizationJobRuleCandidate] = []
        for profile in evidence.senders where profile.canCreateRule {
            guard let sender = MailOrganizationAnalyzer.ruleAddress(profile.address), let examples = incoming[sender],
                  let first = examples.first, let owner = owners[first.id], examples.allSatisfy({ owners[$0.id] == owner }) else { continue }
            result.append(.init(sender: sender, categoryID: owner, messages: examples))
            if result.count == OrganizationJobLimits.maximumRuleSenders { break }
        }
        return result
    }

    private func report(_ stage: OrganizationAnalysisProgress.Stage, done: Int, total: Int, count: Int,
                        progress: @escaping @Sendable (OrganizationAnalysisProgress) async -> Void) async throws {
        try Task.checkCancellation()
        await progress(.init(stage: stage, completedBatches: done, totalBatches: total, analyzedCount: count))
        try Task.checkCancellation()
    }

    private static func chunks<Value>(_ values: [Value], size: Int) -> [[Value]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }

    private static func fingerprint(_ messages: [OrganizationEmail], context: OrganizationContext, model: String) throws -> String {
        var digest = SHA256()
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { digest.update(data: Data($0)) }
            digest.update(data: data)
        }
        append(Data("tern.organization.job.v1".utf8)); append(Data(model.utf8))
        append(Data(context.filterContextAvailable ? [1] : [0]))
        for message in messages {
            try Task.checkCancellation()
            let value: AIJSON = .object([
                "id": .string(message.id), "thread": .string(message.threadID), "sender": .string(message.sender),
                "recipients": .array(message.recipients.map(AIJSON.string)), "subject": .string(message.subject),
                "snippet": .string(message.snippet), "date": message.date.map { .number($0.timeIntervalSince1970) } ?? .null,
                "sent": .bool(message.isSent), "labels": .array(message.labelNames.map(AIJSON.string)),
                "mailing_list": .bool(message.hasMailingListHeaders), "automated": .bool(message.isAutomated),
            ])
            append(try OrganizationJobRequests.canonical(value))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for label in context.labels.sorted(by: { $0.id < $1.id }) { append(try encoder.encode(label)) }
        for rule in context.rules.sorted(by: { $0.id < $1.id }) { append(try encoder.encode(rule)) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
