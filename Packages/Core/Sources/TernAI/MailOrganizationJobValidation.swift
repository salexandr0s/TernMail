import Foundation
import MailOrganization

enum OrganizationJobValidation {
    static func discovery(_ text: String, batch: [OrganizationEmail], namespace: String) throws -> [OrganizationJobTheme] {
        let values = try rows(text, key: "categories", keys: ["name", "explanation", "kind", "message_ids"])
        guard values.count <= OrganizationJobLimits.maximumCategories else { throw MailOrganizationError.invalidResponse }
        let supplied = Set(batch.map(\.id))
        var topics = Set<String>(), states = Set<String>(), names = Set<String>()
        return try values.enumerated().map { index, value in
            let (name, explanation, kind) = try identity(value)
            guard names.insert(MailOrganizationAnalyzer.labelKey(name)).inserted else { throw MailOrganizationError.invalidResponse }
            let ids = try strings(value["message_ids"])
            guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: supplied) else {
                throw MailOrganizationError.invalidResponse
            }
            if kind == .topic {
                guard topics.isDisjoint(with: ids) else { throw MailOrganizationError.invalidResponse }
                topics.formUnion(ids)
            } else {
                guard states.isDisjoint(with: ids) else { throw MailOrganizationError.invalidResponse }
                states.formUnion(ids)
            }
            return OrganizationJobTheme(id: "\(namespace):\(index)", name: name, explanation: explanation,
                                        kind: kind, existingLabelID: nil, messageIDs: ids)
        }
    }

    static func consolidation(_ text: String, sources: [OrganizationJobTheme], context: OrganizationContext,
                              availableLabelIDs: Set<String>, order: [String: Int], namespace: String) throws -> [OrganizationJobTheme] {
        let values = try rows(text, key: "categories", keys: ["name", "explanation", "kind", "source_ids", "existing_label_id"])
        guard values.count <= OrganizationJobLimits.maximumCategories else { throw MailOrganizationError.invalidResponse }
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let labels = Dictionary(uniqueKeysWithValues: context.labels.map { ($0.id, $0) })
        var used = Set<String>(), names = Set<String>(), labelIDs = Set<String>()
        let result = try values.enumerated().map { index, value -> OrganizationJobTheme in
            var (name, explanation, kind) = try identity(value)
            let ids = try strings(value["source_ids"])
            guard !ids.isEmpty, Set(ids).count == ids.count, used.isDisjoint(with: ids),
                  ids.allSatisfy({ sourceByID[$0]?.kind == kind }) else { throw MailOrganizationError.invalidResponse }
            used.formUnion(ids)
            let members = ids.compactMap { sourceByID[$0] }
            let target: String?
            if value["existing_label_id"] == .null {
                let matches = context.labels.filter { MailOrganizationAnalyzer.labelKey($0.name) == MailOrganizationAnalyzer.labelKey(name) }
                guard matches.count <= 1 else { throw MailOrganizationError.invalidResponse }
                target = matches.first?.id
            } else {
                guard let id = value["existing_label_id"]?.stringValue, availableLabelIDs.contains(id), labels[id] != nil else {
                    throw MailOrganizationError.invalidResponse
                }
                target = id
            }
            if let target, let label = labels[target] {
                name = label.name
                guard labelIDs.insert(target).inserted else { throw MailOrganizationError.invalidResponse }
            } else if members.contains(where: { $0.existingLabelID != nil }) {
                // A later catalogue partition cannot forget an already chosen existing label.
                throw MailOrganizationError.invalidResponse
            }
            guard MailOrganizationAnalyzer.validLabelName(name),
                  names.insert(MailOrganizationAnalyzer.labelKey(name)).inserted,
                  validKind(name: name, kind: kind) else { throw MailOrganizationError.invalidResponse }
            let messages = Set(members.flatMap(\.messageIDs)).sorted {
                let first = order[$0, default: Int.max], second = order[$1, default: Int.max]
                return first == second ? $0 < $1 : first < second
            }
            return .init(id: "\(namespace):\(index)", name: name, explanation: explanation, kind: kind,
                         existingLabelID: target, messageIDs: messages)
        }
        guard used == Set(sourceByID.keys) else { throw MailOrganizationError.invalidResponse }
        return result
    }

    static func audit(_ text: String, batch: [OrganizationEmail], taxonomy: [OrganizationJobTheme]) throws -> [OrganizationJobAssignment] {
        let values = try rows(text, key: "assignments", keys: ["category_id", "message_ids"])
        guard values.count <= taxonomy.count else { throw MailOrganizationError.invalidResponse }
        let kinds = Dictionary(uniqueKeysWithValues: taxonomy.map { ($0.id, $0.kind) })
        let supplied = Set(batch.map(\.id))
        var categories = Set<String>(), topics = Set<String>(), states = Set<String>()
        return try values.map { value in
            guard let id = value["category_id"]?.stringValue, let kind = kinds[id], categories.insert(id).inserted else {
                throw MailOrganizationError.invalidResponse
            }
            let ids = try strings(value["message_ids"])
            guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: supplied) else {
                throw MailOrganizationError.invalidResponse
            }
            if kind == .topic {
                guard topics.isDisjoint(with: ids) else { throw MailOrganizationError.invalidResponse }
                topics.formUnion(ids)
            } else {
                guard states.isDisjoint(with: ids) else { throw MailOrganizationError.invalidResponse }
                states.formUnion(ids)
            }
            return .init(categoryID: id, messageIDs: ids)
        }
    }

    static func rules(_ text: String, candidates: [OrganizationJobRuleCandidate]) throws -> [String] {
        let value = try object(text)
        guard Set(value.keys) == ["approved_senders"] else { throw MailOrganizationError.invalidResponse }
        let raw = try strings(value["approved_senders"])
        let addresses = raw.compactMap(MailOrganizationAnalyzer.ruleAddress)
        guard raw.count == addresses.count, Set(addresses).count == addresses.count,
              Set(addresses).isSubset(of: Set(candidates.map(\.sender))) else { throw MailOrganizationError.invalidResponse }
        return addresses
    }

    static func prepare(_ messages: [OrganizationEmail], context: OrganizationContext, model: String) throws -> [OrganizationEmail] {
        guard messages.count <= OrganizationJobLimits.maximumMessages, Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ valid($0.id, 128) && valid($0.threadID, 128)
                  && ($0.date?.timeIntervalSinceReferenceDate.isFinite ?? true) }),
              valid(model, 200), !model.unicodeScalars.contains(where: { $0.properties.isWhitespace }),
              Set(context.labels.map(\.id)).count == context.labels.count,
              context.labels.allSatisfy({ valid($0.id, 128) && valid($0.name, 1_024) }),
              Set(context.rules.map(\.id)).count == context.rules.count,
              context.rules.allSatisfy({ valid($0.id, 128) && $0.labelIDs.count <= 1_000
                  && $0.labelIDs.allSatisfy({ valid($0, 128) })
                  && $0.criteria.utf8.count <= 32_768 && $0.actions.utf8.count <= 32_768 }) else {
            throw MailOrganizationError.invalidInput
        }
        return messages.sorted {
            let first = $0.date ?? .distantPast, second = $1.date ?? .distantPast
            return first == second ? $0.id < $1.id : first > second
        }
    }

    private static func rows(_ text: String, key: String, keys: Set<String>) throws -> [[String: AIJSON]] {
        let value = try object(text)
        guard Set(value.keys) == [key], let rows = value[key]?.arrayValue else { throw MailOrganizationError.invalidResponse }
        return try rows.map { row in
            guard let row = row.objectValue, Set(row.keys) == keys else { throw MailOrganizationError.invalidResponse }
            return row
        }
    }

    private static func object(_ text: String) throws -> [String: AIJSON] {
        do {
            guard let value = try AIJSON.decode(Data(text.utf8)).objectValue else { throw MailOrganizationError.invalidResponse }
            return value
        } catch { throw MailOrganizationError.invalidResponse }
    }

    private static func strings(_ value: AIJSON?) throws -> [String] {
        guard let array = value?.arrayValue else { throw MailOrganizationError.invalidResponse }
        let strings = array.compactMap(\.stringValue)
        guard strings.count == array.count else { throw MailOrganizationError.invalidResponse }
        return strings
    }

    private static func identity(_ value: [String: AIJSON]) throws -> (String, String, OrganizationCategory.Kind) {
        guard let name = value["name"]?.stringValue, MailOrganizationAnalyzer.validLabelName(name),
              let explanation = value["explanation"]?.stringValue, valid(explanation, 600),
              let raw = value["kind"]?.stringValue, let kind = OrganizationCategory.Kind(rawValue: raw),
              validKind(name: name, kind: kind) else { throw MailOrganizationError.invalidResponse }
        return (name, explanation, kind)
    }

    private static func validKind(name: String, kind: OrganizationCategory.Kind) -> Bool {
        let key = MailOrganizationAnalyzer.labelKey(name)
        return (key != "action" || kind == .action) && (key != "waiting" || kind == .waiting)
    }

    private static func valid(_ text: String, _ limit: Int) -> Bool { MailOrganizationAnalyzer.validText(text, maximumBytes: limit) }
}
