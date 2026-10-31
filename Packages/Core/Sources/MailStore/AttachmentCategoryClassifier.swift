import Foundation

/// Local document-purpose detection. Uncertain evidence leaves the file uncategorized.
public enum AttachmentCategoryClassifier {
    public static let supportedLanguages = AttachmentClassificationLanguagePack.all.map(\.language)
    public static let ocrLanguageCodes = supportedLanguages.map(\.ocrLanguageCode)

    public static func classify(filename: String, mimeType: String, subject: String, text: String? = nil) -> AttachmentCategory {
        let suffix = (filename as NSString).pathExtension.lowercased()
        let name = normalized((filename as NSString).deletingPathExtension)
        let subject = normalized(String(subject.prefix(2_000)))
        guard isDocument(suffix: suffix, mimeType: mimeType) else { return .uncategorized }
        if contains(name, any: decorations) { return .uncategorized }
        if contains(name, any: companionDocuments) { return .other }

        // Wallet passes are structured tickets even when their filename is opaque.
        if suffix == "pkpass" || mimeType.lowercased().hasPrefix("application/vnd.apple.pkpass") { return .ticket }

        let body = String((text ?? "").prefix(60_000))
        let content = normalized(body)
        let supportContext = contains(subject, any: supportTerms) || contains(name, any: supportTerms)
        let named = evidence(in: name, supportContext: supportContext, includesFilenameTerms: true)

        // A document title is stronger than its download filename. Restrict this
        // to short lines so ordinary references in paragraphs are not titles.
        var headingScores: [AttachmentCategory: Int] = [:]
        for line in body.split(whereSeparator: \.isNewline).prefix(12) {
            let heading = normalized(String(line))
            guard heading.count <= 100 else { continue }
            if documentFieldTerms.contains(where: { heading == $0 || heading.hasPrefix($0 + " ") }) { continue }
            for (category, terms) in purposeTerms where terms.contains(where: { isHeading(heading, term: $0) }) {
                if category == .ticket && supportContext && !contains(heading, any: travelTerms) { continue }
                headingScores[category] = 1
            }
        }
        if let heading = winner(headingScores) { return heading }
        if let namedCategory = winner(named) { return namedCategory }

        var contentScores = evidence(in: content, supportContext: supportContext)
        for rule in contentRules where rule.requiredGroups.values.allSatisfy({ contains(content, any: $0) }) {
            contentScores[rule.category, default: 0] += 3
        }
        if let contentCategory = winner(contentScores) { return contentCategory }

        // Conflicting evidence within the file must not be resolved merely by
        // the email subject, which also describes its other attachments.
        guard named.isEmpty, contentScores.isEmpty else { return .uncategorized }
        if contains(name, any: voucherTerms), contains(name + " " + subject, any: bookingContextTerms), !supportContext { return .ticket }
        return winner(evidence(in: subject, supportContext: supportContext)) ?? .uncategorized
    }

    private static let purposeTerms = categoryTerms(\.purposeTerms)
    private static let filenameTerms = categoryTerms(\.filenameTerms)
    private static let numberedFilenameTerms = categoryTerms(\.numberedFilenameTerms)
    private static let decorations = vocabulary(\.decorationTerms)
    private static let companionDocuments = vocabulary(\.companionTerms)
    private static let supportTerms = vocabulary(\.supportTerms)
    private static let travelTerms = vocabulary(\.travelTerms)
    private static let voucherTerms = vocabulary(\.voucherTerms)
    private static let bookingContextTerms = vocabulary(\.bookingContextTerms)
    private static let headingNumberLabels = vocabulary(\.headingNumberLabels)
    private static let documentFieldTerms = vocabulary(\.documentFieldTerms)
    private static let contentRules: [AttachmentClassificationLanguagePack.ContentRule] = {
        let rules = AttachmentClassificationLanguagePack.all.flatMap(\.contentRules)
        return AttachmentClassificationLanguagePack.ContentRule.ID.allCases.compactMap { id in
            let translations = rules.filter { $0.id == id }
            guard !translations.isEmpty else { return nil }
            // Merge translations of each semantic field, so a Swiss receipt
            // can combine Kartenzahlung with Total without duplicating rules.
            var fields: [AttachmentClassificationLanguagePack.ContentRule.Field: [String]] = [:]
            for rule in translations {
                for (field, terms) in rule.requiredGroups { fields[field, default: []] += terms.map(normalized) }
            }
            return .init(id: id, requiredGroups: fields)
        }
    }()

    private static func evidence(in value: String, supportContext: Bool, includesFilenameTerms: Bool = false) -> [AttachmentCategory: Int] {
        var scores: [AttachmentCategory: Int] = [:]
        for (category, terms) in purposeTerms where contains(value, any: terms) {
            if category == .ticket && supportContext && !contains(value, any: travelTerms) { continue }
            scores[category] = 1
        }
        // Export filenames such as emailreceipt and printinvoicepreview are
        // useful aliases. A generic booking name never overrides Invoice or Receipt.
        if scores.isEmpty, includesFilenameTerms {
            for (category, terms) in numberedFilenameTerms where terms.contains(where: { term in
                (" " + value).components(separatedBy: " " + term + " ").dropFirst().contains { $0.first?.isNumber == true }
            }) {
                scores[category] = 1
            }
            if !scores.isEmpty { return scores }
            for (category, terms) in filenameTerms where contains(value, any: terms) {
                if category == .ticket && supportContext { continue }
                scores[category] = 1
            }
        }
        return scores
    }

    private static func vocabulary(_ keyPath: KeyPath<AttachmentClassificationLanguagePack, [String]>) -> [String] {
        AttachmentClassificationLanguagePack.all.flatMap { $0[keyPath: keyPath] }.map(normalized)
    }

    private static func categoryTerms(_ keyPath: KeyPath<AttachmentClassificationLanguagePack, [AttachmentCategory: [String]]>) -> [(AttachmentCategory, [String])] {
        AttachmentCategory.allCases.compactMap { category in
            let terms = AttachmentClassificationLanguagePack.all.flatMap { $0[keyPath: keyPath][category] ?? [] }.map(normalized)
            return terms.isEmpty ? nil : (category, terms)
        }
    }

    private static func winner(_ scores: [AttachmentCategory: Int]) -> AttachmentCategory? {
        let ranked = scores.sorted { $0.value > $1.value }
        guard let first = ranked.first, ranked.count == 1 || first.value > ranked[1].value else { return nil }
        return first.key
    }

    private static func contains(_ value: String, any terms: [String]) -> Bool {
        let bounded = " " + value + " "
        return terms.contains { bounded.contains(" " + $0 + " ") }
    }

    private static func isHeading(_ value: String, term: String) -> Bool {
        guard value == term || value.hasPrefix(term + " ") else { return false }
        let remainder = value.dropFirst(term.count).trimmingCharacters(in: .whitespaces)
        // A title may carry a document number, date, or a "No." label.
        return remainder.isEmpty || remainder.first?.isNumber == true ||
            headingNumberLabels.contains { remainder == $0 || remainder.hasPrefix($0 + " ") }
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-zäöüß])([A-ZÄÖÜ])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([\\p{L}])([0-9])|([0-9])([\\p{L}])", with: "$1$3 $2$4", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func isDocument(suffix: String, mimeType: String) -> Bool {
        let mime = mimeType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if ["ics", "ical", "vcf"].contains(suffix) || ["text/calendar", "text/vcard", "text/x-vcard"].contains(mime) { return false }
        let extensions: Set<String> = ["pdf", "txt", "text", "csv", "md", "xml", "html", "htm", "rtf", "doc", "docx", "odt",
                                       "xls", "xlsx", "ods", "png", "jpg", "jpeg", "heic", "heif", "bmp", "tif", "tiff", "webp", "gif", "pkpass"]
        if extensions.contains(suffix) { return true }
        return ["application/pdf", "application/rtf", "application/msword", "application/vnd.apple.pkpass"].contains(mime) ||
            mime.hasPrefix("text/") || mime.hasPrefix("image/") ||
            mime.hasPrefix("application/vnd.openxmlformats-officedocument.") || mime.hasPrefix("application/vnd.oasis.opendocument.")
    }
}
