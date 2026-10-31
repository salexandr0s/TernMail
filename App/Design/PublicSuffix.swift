import Foundation

/// Includes the PSL's private section so one hosted customer's icon cannot represent another.
struct PublicSuffix: Sendable {
    static let shared: PublicSuffix = {
        let url = Bundle.main.url(forResource: "PublicSuffixList", withExtension: "dat")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return PublicSuffix(text: text)
    }()

    private let rules: Set<String>
    private let topLevelDomains: Set<String>

    init(text: String) {
        rules = Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { return nil }
            let prefix = rule.hasPrefix("!") ? "!" : rule.hasPrefix("*.") ? "*." : ""
            let host = String(rule.dropFirst(prefix.count))
            return Self.normalizedHost(host).map { prefix + $0 }
        })
        topLevelDomains = Set(rules.compactMap { $0.split(separator: ".").last.map(String.init) })
    }

    func registrableDomain(_ value: String) -> String? {
        guard let host = Self.normalizedHost(value) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard let last = labels.last, topLevelDomains.contains(last) else { return nil }
        var suffixCount = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) {
                suffixCount = labels.count - index - 1
                break
            }
            if rules.contains(suffix) { suffixCount = max(suffixCount, labels.count - index) }
            if index > 0, rules.contains("*." + suffix) { suffixCount = max(suffixCount, labels.count - index + 1) }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }

    static func normalizedHost(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 253,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains(where: { "/\\:@?#%[]".contains($0) }),
              let host = URL(string: "https://" + value)?.host?.lowercased(), host.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 1, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }
}
