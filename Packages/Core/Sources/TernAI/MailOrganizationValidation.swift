import Foundation

extension MailOrganizationAnalyzer {
    /// Gmail reserves its own names. Category output and edits use the same rules;
    /// the mail layer also checks names against the account's actual system labels.
    public static func validLabelName(_ name: String) -> Bool {
        let reserved: Set<String> = [
            "inbox", "sent", "draft", "drafts", "spam", "trash", "starred", "important",
            "unread", "chat", "chats", "all mail", "sent mail", "deleted items",
        ]
        let key = labelKey(name)
        return validText(name, maximumBytes: 225)
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            && !reserved.contains(key) && !key.hasPrefix("category_")
    }

    private static func labelKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A conservative subset of bare addresses that is safe to put in a Gmail
    /// sender criterion. Unusual quoted addresses can still receive sample labels.
    static func ruleAddress(_ value: String) -> String? {
        guard value.utf8.count <= 254, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = parts[0], domain = parts[1]
        let localCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-")
        let domainCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !local.isEmpty, local.utf8.count <= 64, !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
              local.unicodeScalars.allSatisfy(localCharacters.contains) else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.unicodeScalars.allSatisfy(domainCharacters.contains)
        }) else { return nil }
        return value.lowercased()
    }

    static func decode(_ text: String, messages: [OrganizationEmail], existingLabelNames: [String]) throws -> OrganizationPlan {
        do {
            let data = Data(text.utf8)
            let object = try AIJSON.decode(data).objectValue
            guard let object, Set(object.keys) == ["categories"], let categories = object["categories"]?.arrayValue,
                  categories.count <= maximumCategories, categories.allSatisfy({
                      $0.objectValue.map { Set($0.keys) == ["name", "explanation", "kind", "message_ids", "rule_senders"] } ?? false
                  }) else { throw MailOrganizationError.invalidResponse }
            let result = try JSONDecoder().decode(Result.self, from: data)
            return try validate(result, messages: messages, existingLabelNames: existingLabelNames)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Codable errors can include email text or model output.
            throw MailOrganizationError.invalidResponse
        }
    }

    private static func validate(_ result: Result, messages: [OrganizationEmail], existingLabelNames: [String]) throws -> OrganizationPlan {
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let byThread = Dictionary(grouping: messages, by: \.threadID)
        let incoming = Dictionary(grouping: messages.filter { !$0.isSent }, by: { ruleAddress($0.sender) ?? "" })
        var names = Set<String>()
        var topicIDs = Set<String>()
        var stateIDs = Set<String>()
        var ruleOwners = Set<String>()
        var categories: [OrganizationCategory] = []
        for category in result.categories {
            try Task.checkCancellation()
            let key = labelKey(category.name)
            guard validLabelName(category.name), names.insert(key).inserted,
                  (key != "action" || category.kind == .action),
                  (key != "waiting" || category.kind == .waiting),
                  validText(category.explanation, maximumBytes: 600),
                  !category.messageIDs.isEmpty, category.messageIDs.count <= maximumMessages,
                  Set(category.messageIDs).count == category.messageIDs.count,
                  category.messageIDs.allSatisfy({ byID[$0] != nil }),
                  category.ruleSenders.count <= 20 else { throw MailOrganizationError.invalidResponse }
            let ids = Set(category.messageIDs)
            switch category.kind {
            case .topic:
                guard topicIDs.isDisjoint(with: ids) else { throw MailOrganizationError.invalidResponse }
                topicIDs.formUnion(ids)
            case .action, .waiting:
                guard category.ruleSenders.isEmpty, stateIDs.isDisjoint(with: ids) else { throw MailOrganizationError.invalidResponse }
                for id in category.messageIDs {
                    guard let message = byID[id], let thread = byThread[message.threadID],
                          thread.allSatisfy({ $0.date != nil }), thread.first?.id == id,
                          message.isSent == (category.kind == .waiting) else { throw MailOrganizationError.invalidResponse }
                }
                stateIDs.formUnion(ids)
            }
            var senders: [String] = []
            for raw in category.ruleSenders {
                guard let sender = ruleAddress(raw), ruleOwners.insert(sender).inserted,
                      ruleOwners.count <= maximumRuleSenders,
                      let examples = incoming[sender], examples.count >= 2,
                      examples.allSatisfy({ ids.contains($0.id) }) else { throw MailOrganizationError.invalidResponse }
                senders.append(sender)
            }
            let name = existingLabelNames.first { labelKey($0) == key } ?? category.name
            categories.append(OrganizationCategory(id: "category:" + key, name: name,
                explanation: category.explanation, kind: category.kind,
                messageIDs: messages.filter { ids.contains($0.id) }.map(\.id), ruleSenders: senders.sorted()))
        }
        return OrganizationPlan(categories: categories, analyzedCount: messages.count)
    }

    private struct Result: Decodable {
        let categories: [Category]
    }

    private struct Category: Decodable {
        let name: String
        let explanation: String
        let kind: OrganizationCategory.Kind
        let messageIDs: [String]
        let ruleSenders: [String]
        enum CodingKeys: String, CodingKey {
            case name, explanation, kind
            case messageIDs = "message_ids"
            case ruleSenders = "rule_senders"
        }
    }
}
