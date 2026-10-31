import Testing
@testable import MailStore

@Suite struct AttachmentCategoryClassifierTests {
    @Test(arguments: [
        ("Invoice2026-1042.PDF", AttachmentCategory.invoice),
        ("Rechnung_2026_123.pdf", .invoice),
        ("TaxInvoice.pdf", .invoice),
        ("receipt-826.png", .receipt),
        ("Quittung123.jpg", .receipt),
        ("Zahlungsbestätigung.pdf", .receipt),
        ("Kassenbon.pdf", .receipt),
        ("BoardingPass.pdf", .ticket),
        ("e-ticket_84.pdf", .ticket),
        ("ExampleRail_Fahrkarte.pdf", .ticket),
        ("Buchungsbestätigung.pdf", .ticket),
        ("Buchungsbestaetigung.pdf", .ticket),
        ("Mietvertrag.pdf", .contract),
        ("ServiceAgreement.docx", .contract),
        ("a8b7c6.pkpass", .ticket)
    ])
    func filenamesIdentifyDocumentPurpose(_ filename: String, _ expected: AttachmentCategory) {
        #expect(AttachmentCategoryClassifier.classify(filename: filename, mimeType: "application/octet-stream", subject: "Your documents") == expected)
    }

    @Test(arguments: [
        ("Your invoice for October", AttachmentCategory.invoice),
        ("Ihre Rechnung ist da", .invoice),
        ("Payment receipt for your order", .receipt),
        ("Your booking confirmation", .ticket),
        ("Ihre Buchungsbestätigung", .ticket),
        ("Your signed contract", .contract)
    ])
    func opaqueNamesUseEmailContext(_ subject: String, _ expected: AttachmentCategory) {
        #expect(AttachmentCategoryClassifier.classify(filename: "123456789.pdf", mimeType: "application/pdf", subject: subject) == expected)
    }

    @Test(arguments: ["scan.heif", "scan.bmp", "document.md"])
    func extractedFormatsWithGenericMimeTypeRemainEligible(_ filename: String) {
        #expect(AttachmentCategoryClassifier.classify(filename: filename, mimeType: "application/octet-stream",
            subject: "Document", text: "RECEIPT\nTotal 49 EUR\nPayment received") == .receipt)
    }

    @Test func documentEvidenceBeatsEmailContextAndDownloadNames() {
        #expect(AttachmentCategoryClassifier.classify(filename: "receipt.pdf", mimeType: "application/pdf",
            subject: "Your tickets and receipt") == .receipt)
        #expect(AttachmentCategoryClassifier.classify(filename: "download.pdf", mimeType: "application/pdf",
            subject: "Your receipt", text: "ACME\nINVOICE #123\nTotal 240 EUR\nPlease keep this document for your records.") == .invoice)
        #expect(AttachmentCategoryClassifier.classify(filename: "invoice.pdf", mimeType: "application/pdf",
            subject: "Invoice", text: "RECEIPT\nTransaction 123\nTotal 240 EUR\nPayment received") == .receipt)
        #expect(AttachmentCategoryClassifier.classify(filename: "scan.jpg", mimeType: "image/jpeg",
            subject: "Document", text: "RECHNUNG\nNummer 2026-32\nGesamt 49 EUR") == .invoice)
        #expect(AttachmentCategoryClassifier.classify(filename: "document.pdf", mimeType: "application/pdf",
            subject: "Document", text: "Passenger Jane Example\nFlight 123\nGate A2\nSeat 14C\nDeparture 14:00") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "IMG_1234.jpeg", mimeType: "image/jpeg",
            subject: "Document", text: "Kartenzahlung\nGesamt 49 EUR\nBetrag 49 EUR") == .receipt)
    }

    @Test func companionsAndSupportRequestsDoNotBecomeFinancialDocumentsOrTravelTickets() {
        for filename in ["logo.png", "signature.jpg", "banner.png"] {
            #expect(AttachmentCategoryClassifier.classify(filename: filename, mimeType: "image/png", subject: "Your invoice") == .uncategorized)
        }
        for filename in ["terms.pdf", "AGB.pdf", "payment-instructions.pdf", "InvoiceTemplate.docx"] {
            #expect(AttachmentCategoryClassifier.classify(filename: filename, mimeType: "application/pdf", subject: "Your invoice and tickets") == .other)
        }
        for filename in ["screenshot.png", "ticket-123.pdf"] {
            #expect(AttachmentCategoryClassifier.classify(filename: filename, mimeType: "application/pdf", subject: "Support ticket 123 updated") == .uncategorized)
        }
        #expect(AttachmentCategoryClassifier.classify(filename: "BoardingPass.pdf", mimeType: "application/pdf", subject: "Support: your replacement ticket") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "invoice.zip", mimeType: "application/zip", subject: "Your invoice") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "cricket.pdf", mimeType: "application/pdf", subject: "Notes") == .uncategorized)
    }

    @Test func ambiguousOrAbsentEvidenceStaysUncategorized() {
        #expect(AttachmentCategoryClassifier.classify(filename: "document.pdf", mimeType: "application/pdf", subject: "Your files") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "document.pdf", mimeType: "application/pdf", subject: "Your invoice and receipt") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "invoice-receipt.pdf", mimeType: "application/pdf", subject: "Invoice") == .uncategorized)
    }
}
