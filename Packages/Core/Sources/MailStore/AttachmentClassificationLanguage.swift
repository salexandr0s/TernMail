/// Supported document vocabulary and its matching on-device OCR language.
public struct AttachmentClassificationLanguage: Sendable, Equatable {
    public let languageCode: String
    public let ocrLanguageCode: String
}

struct AttachmentClassificationLanguagePack: Sendable {
    struct ContentRule: Sendable {
        enum ID: CaseIterable, Sendable {
            case invoiceAmount, paymentReceipt, journey, rentalVoucher, cinemaAdmission

            var category: AttachmentCategory {
                switch self {
                case .invoiceAmount: .invoice
                case .paymentReceipt: .receipt
                case .journey, .rentalVoucher, .cinemaAdmission: .ticket
                }
            }
        }
        enum Field: Sendable {
            case invoiceNumber, amount, payment, movement, traveler, voucher, pickup, returnTime, cinema, screen, position
        }
        let id: ID
        let requiredGroups: [Field: [String]]
        var category: AttachmentCategory { id.category }
    }

    let language: AttachmentClassificationLanguage
    let purposeTerms: [AttachmentCategory: [String]]
    let filenameTerms: [AttachmentCategory: [String]]
    let numberedFilenameTerms: [AttachmentCategory: [String]]
    let decorationTerms: [String]
    let companionTerms: [String]
    let supportTerms: [String]
    let travelTerms: [String]
    let voucherTerms: [String]
    let bookingContextTerms: [String]
    let headingNumberLabels: [String]
    let documentFieldTerms: [String]
    let contentRules: [ContentRule]

    // Packs are combined for every mailbox; the system's UI language does not
    // restrict which documents can be recognized. Add future vocabulary here.
    static let all = [english, german]

    private static let english = AttachmentClassificationLanguagePack(
        language: .init(languageCode: "en", ocrLanguageCode: "en-US"),
        purposeTerms: [
            .invoice: ["invoice", "invoices", "tax invoice", "vat invoice"],
            .receipt: ["receipt", "receipts", "payment receipt", "payment confirmation", "payment confirmations", "proof of payment"],
            .contract: ["contract", "contracts", "agreement", "agreements", "lease", "nda", "non disclosure agreement"],
            .ticket: ["ticket", "tickets", "eticket", "etickets", "e ticket", "electronic ticket", "boarding pass", "boardingpass",
                      "booking confirmation", "booking confirmations", "booking is confirmed", "reservation confirmation",
                      "reservation is confirmed", "travel reservation", "itinerary"]
        ],
        filenameTerms: [
            .invoice: ["printinvoicepreview"],
            .receipt: ["emailreceipt"],
            .ticket: ["booking", "booking documents", "booking com confirmation"]
        ],
        numberedFilenameTerms: [.invoice: ["inv"]],
        decorationTerms: ["logo", "logos", "icon", "icons", "avatar", "banner", "signature", "spacer", "tracking pixel"],
        companionTerms: ["terms", "terms and conditions", "conditions of carriage", "fare conditions", "fareconditions", "privacy",
                         "payment instructions", "payment fees", "payment fee", "instructions", "template", "sample", "brochure", "manual",
                         "cancellation form", "cancellation forms", "cancellation policy", "cancellation notice", "refund form", "refund forms",
                         "airport map", "airport maps", "terminal map", "seat map", "passport", "identity card"],
        supportTerms: ["support", "helpdesk", "help desk", "incident", "bug", "service request", "ticket status", "ticket resolved"],
        travelTerms: ["boarding", "boardingpass", "electronic ticket", "itinerary", "booking confirmation", "booking is confirmed", "travel reservation"],
        voucherTerms: ["voucher", "vouchers"],
        bookingContextTerms: ["booking", "reservation", "travel", "hotel", "flight"],
        headingNumberLabels: ["number", "no"],
        documentFieldTerms: ["invoice number", "invoice no"],
        contentRules: [
            .init(id: .invoiceAmount, requiredGroups: [.invoiceNumber: ["invoice number", "invoice no"], .amount: ["amount due", "total", "balance due"]]),
            .init(id: .paymentReceipt, requiredGroups: [.payment: ["amount paid", "paid by", "payment received"], .amount: ["transaction", "total"]]),
            .init(id: .journey, requiredGroups: [.movement: ["boarding", "departure", "flight"], .traveler: ["seat", "gate", "passenger", "reservation", "booking"]]),
            .init(id: .rentalVoucher, requiredGroups: [.voucher: ["rental voucher", "car rental voucher"], .pickup: ["pickup", "pick up", "collection"], .returnTime: ["return", "drop off", "dropoff"]]),
            .init(id: .cinemaAdmission, requiredGroups: [.cinema: ["cinema"], .screen: ["screen"], .position: ["row", "seat"]])
        ]
    )

    private static let german = AttachmentClassificationLanguagePack(
        language: .init(languageCode: "de", ocrLanguageCode: "de-DE"),
        purposeTerms: [
            .invoice: ["Rechnung", "Rechnungen", "Rechnungskopie", "Rechnungsnummer", "Rechnungsnr", "Rechnungs Nr",
                       "Faktura", "Honorarnote"],
            .receipt: ["Quittung", "Quittungen", "Beleg", "Belege", "Kaufbeleg", "Kaufbelege", "Zahlungsbeleg",
                       "Zahlungsbestätigung", "Zahlungsbestaetigung", "Kassenbon", "Kassenzettel"],
            .contract: ["Vertrag", "Verträge", "Vertraege", "Mietvertrag", "Arbeitsvertrag", "Dienstvertrag", "Kaufvertrag"],
            .ticket: ["Bordkarte", "Bordkarten", "Fahrkarte", "Fahrkarten", "Fahrschein", "Bahnticket", "Zugticket", "Flugticket",
                      "Eintrittskarte", "Konzertticket", "Buchungsbestätigung", "Buchungsbestaetigung", "Reservierungsbestätigung",
                      "Reservierungsbestaetigung", "Reiseplan", "Billett", "Billette", "Mehrfachkarte", "Online Ticket"]
        ],
        filenameTerms: [.ticket: ["Buchungsunterlagen", "Reiseunterlagen"]],
        numberedFilenameTerms: [:],
        decorationTerms: ["Signatur"],
        companionTerms: ["AGB", "Datenschutz", "Zahlungsanleitung", "Zahlungsgebühren", "Zahlungsgebuehren", "Anleitung", "Vorlage", "Muster",
                         "Broschüre", "Widerrufsbelehrung", "Widerrufsformular", "Stornoformular", "Stornobedingungen", "Tarifbedingungen",
                         "Flughafenplan", "Reisepass", "Passkopie", "Personalausweis", "Identitätskarte", "Mietwertberechnung"],
        supportTerms: ["Supportanfrage", "Kundendienst", "Störung", "Stoerung"],
        travelTerms: ["Bordkarte", "Fahrkarte", "Fahrschein", "Bahnticket", "Zugticket", "Flugticket", "Eintrittskarte", "Konzertticket",
                      "Buchungsbestätigung", "Buchungsbestaetigung", "Billett", "Billette", "Mehrfachkarte"],
        voucherTerms: ["Gutschein"],
        bookingContextTerms: ["Buchung", "Reservierung", "Reise", "Hotel", "Flug"],
        headingNumberLabels: ["Nr", "Nummer"],
        documentFieldTerms: ["Rechnungsnummer", "Rechnungsnr", "Rechnungs Nr"],
        contentRules: [
            .init(id: .invoiceAmount, requiredGroups: [.invoiceNumber: ["Rechnungsnummer", "Rechnungsnr", "Rechnungs Nr"], .amount: ["zahlbar", "Gesamt", "Rechnungsbetrag"]]),
            .init(id: .paymentReceipt, requiredGroups: [.payment: ["Zahlung erhalten", "bezahlt", "Kartenzahlung"], .amount: ["Gesamt", "Betrag", "Summe"]]),
            .init(id: .journey, requiredGroups: [.movement: ["Abfahrt", "Flugnummer", "Einlass"], .traveler: ["Sitzplatz", "Reisender", "Buchung"]]),
            .init(id: .rentalVoucher, requiredGroups: [.voucher: ["Mietwagen Voucher", "Mietwagengutschein", "Mietwagenvoucher"], .pickup: ["Abholung"], .returnTime: ["Rückgabe", "Rueckgabe"]])
        ]
    )
}
