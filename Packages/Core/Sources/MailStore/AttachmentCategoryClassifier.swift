import Foundation

/// Local document-purpose detection. Uncertain evidence leaves the file uncategorized.
public enum AttachmentCategoryClassifier {
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
        let named = evidence(in: name, supportContext: supportContext)

        // A document title is stronger than its download filename. Restrict this
        // to short lines so ordinary references in paragraphs are not titles.
        var headingScores: [AttachmentCategory: Int] = [:]
        for line in body.split(whereSeparator: \.isNewline).prefix(12) {
            let heading = normalized(String(line))
            guard heading.count <= 100 else { continue }
            for (category, terms) in purposeTerms where terms.contains(where: { isHeading(heading, term: $0) }) {
                if category == .ticket && supportContext && !contains(heading, any: travelTerms) { continue }
                headingScores[category] = 1
            }
        }
        if let heading = winner(headingScores) { return heading }
        if let namedCategory = winner(named) { return namedCategory }

        var contentScores = evidence(in: content, supportContext: supportContext)
        if contains(content, any: ["invoice number", "invoice no", "rechnungsnummer", "rechnungsnr"]),
           contains(content, any: ["amount due", "total", "balance due", "zahlbar", "gesamt", "rechnungsbetrag"]) {
            contentScores[.invoice, default: 0] += 3
        }
        if contains(content, any: ["amount paid", "paid by", "payment received", "zahlung erhalten", "bezahlt", "kartenzahlung"]),
           contains(content, any: ["transaction", "total", "gesamt", "betrag", "summe"]) {
            contentScores[.receipt, default: 0] += 3
        }
        if contains(content, any: ["boarding", "departure", "abfahrt", "flugnummer", "flight", "einlass"]),
           contains(content, any: ["seat", "sitzplatz", "gate", "passenger", "reisender", "reservation", "buchung"]) {
            contentScores[.ticket, default: 0] += 3
        }
        if let contentCategory = winner(contentScores) { return contentCategory }

        // Conflicting evidence within the file must not be resolved merely by
        // the email subject, which also describes its other attachments.
        guard named.isEmpty, contentScores.isEmpty else { return .uncategorized }
        return winner(evidence(in: subject, supportContext: supportContext)) ?? .uncategorized
    }

    private static let purposeTerms: [(AttachmentCategory, [String])] = [
        (.invoice, ["invoice", "invoices", "tax invoice", "vat invoice", "rechnung", "rechnungen", "faktura", "honorarnote"]),
        (.receipt, ["receipt", "receipts", "payment receipt", "payment confirmation", "proof of payment", "quittung", "quittungen",
                    "beleg", "zahlungsbeleg", "zahlungsbestatigung", "zahlungsbestaetigung", "kassenbon", "kassenzettel"]),
        (.contract, ["contract", "contracts", "agreement", "agreements", "vertrag", "vertrage", "vertraege", "mietvertrag",
                     "arbeitsvertrag", "dienstvertrag", "kaufvertrag", "lease", "nda", "non disclosure agreement"]),
        (.ticket, ["ticket", "tickets", "eticket", "etickets", "e ticket", "boarding pass", "boardingpass", "bordkarte", "bordkarten",
                   "fahrkarte", "fahrkarten", "fahrschein", "bahnticket", "zugticket", "flugticket", "eintrittskarte", "konzertticket",
                   "booking confirmation", "reservation confirmation", "buchungsbestatigung", "buchungsbestaetigung",
                   "reservierungsbestatigung", "reservierungsbestaetigung", "itinerary", "reiseplan"])
    ]
    private static let decorations = ["logo", "logos", "icon", "icons", "avatar", "banner", "signature", "signatur", "spacer", "tracking pixel"]
    private static let companionDocuments = ["terms", "terms and conditions", "conditions of carriage", "agb", "privacy", "datenschutz",
                                             "payment instructions", "zahlungsanleitung", "instructions", "anleitung", "template", "vorlage",
                                             "sample", "muster", "brochure", "broschure", "manual"]
    private static let supportTerms = ["support", "helpdesk", "help desk", "incident", "bug", "supportanfrage", "kundendienst", "störung", "storung"]
    private static let travelTerms = ["boarding", "boardingpass", "bordkarte", "fahrkarte", "fahrschein", "bahnticket", "zugticket",
                                      "flugticket", "eintrittskarte", "konzertticket", "itinerary", "booking confirmation", "buchungsbestatigung"]

    private static func evidence(in value: String, supportContext: Bool) -> [AttachmentCategory: Int] {
        var scores: [AttachmentCategory: Int] = [:]
        for (category, terms) in purposeTerms where contains(value, any: terms) {
            if category == .ticket && supportContext && !contains(value, any: travelTerms) { continue }
            scores[category] = 1
        }
        return scores
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
            ["number ", "no ", "nr ", "nummer "].contains(where: remainder.hasPrefix)
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-zäöüß])([A-ZÄÖÜ])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([\\p{L}])([0-9])|([0-9])([\\p{L}])", with: "$1$3 $2$4", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func isDocument(suffix: String, mimeType: String) -> Bool {
        let extensions: Set<String> = ["pdf", "txt", "text", "csv", "md", "xml", "html", "htm", "rtf", "doc", "docx", "odt",
                                       "xls", "xlsx", "ods", "png", "jpg", "jpeg", "heic", "heif", "bmp", "tif", "tiff", "webp", "gif", "pkpass"]
        if extensions.contains(suffix) { return true }
        let mime = mimeType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return ["application/pdf", "application/rtf", "application/msword", "application/vnd.apple.pkpass"].contains(mime) ||
            mime.hasPrefix("text/") || mime.hasPrefix("image/") ||
            mime.hasPrefix("application/vnd.openxmlformats-officedocument.") || mime.hasPrefix("application/vnd.oasis.opendocument.")
    }
}
