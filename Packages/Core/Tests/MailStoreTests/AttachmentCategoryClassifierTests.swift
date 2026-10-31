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
        ("ExampleShop_Kaufbeleg_123.pdf", .receipt),
        ("ExampleShop_Rechnungskopie_INV_2026_01_0001.pdf", .invoice),
        ("emailreceipt_123.pdf", .receipt),
        ("printinvoicepreview (6).pdf", .invoice),
        ("INV_111111111_222222222_202601010900.pdf", .invoice),
        ("Travel Reservation 01JAN for Example.pdf", .ticket),
        ("Booking-Documents.pdf", .ticket),
        ("Booking-example-airline.pdf", .ticket),
        ("booking.example_ Confirmation.pdf", .ticket),
        ("ExampleRail_Billett.pdf", .ticket),
        ("Billette.pdf", .ticket),
        ("Mehrfachkarte.pdf", .ticket),
        ("Online-Ticket.pdf", .ticket),
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
        ("Ihre Beispielshop Rechnungsnummer TEST123", .invoice),
        ("Dein Kaufbeleg", .receipt),
        ("Your payment confirmations", .receipt),
        ("Your booking is confirmed", .ticket),
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
        for filename in ["terms.pdf", "AGB.pdf", "payment-instructions.pdf", "InvoiceTemplate.docx", "payment fees.pdf",
                         "cancellation forms.pdf", "Widerrufsbelehrung.pdf", "AirportMap.pdf", "FareConditions.pdf",
                         "Reisepass.pdf", "Mietwertberechnung.pdf"] {
            #expect(AttachmentCategoryClassifier.classify(filename: filename, mimeType: "application/pdf", subject: "Your invoice and tickets") == .other)
        }
        for filename in ["screenshot.png", "ticket-123.pdf"] {
            #expect(AttachmentCategoryClassifier.classify(filename: filename, mimeType: "application/pdf", subject: "Support ticket 123 updated") == .uncategorized)
        }
        #expect(AttachmentCategoryClassifier.classify(filename: "BoardingPass.pdf", mimeType: "application/pdf", subject: "Support: your replacement ticket") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "invoice.zip", mimeType: "application/zip", subject: "Your invoice") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "flight.ics", mimeType: "text/calendar", subject: "Your booking is confirmed") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "cricket.pdf", mimeType: "application/pdf", subject: "Notes") == .uncategorized)
    }

    @Test func vouchersNeedBookingContextAndMixedTicketReceiptsNeedDocumentEvidence() {
        #expect(AttachmentCategoryClassifier.classify(filename: "voucher.pdf", mimeType: "application/pdf",
            subject: "Voucher zur Buchung Nr. TEST001 in Example City") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "voucher.pdf", mimeType: "application/pdf",
            subject: "Your gift voucher") == .uncategorized)
        let mixedName = "Your Electronic Ticket-EMD Receipt.pdf"
        #expect(AttachmentCategoryClassifier.classify(filename: mixedName, mimeType: "application/pdf",
            subject: "Your documents") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: mixedName, mimeType: "application/pdf",
            subject: "Your documents", text: "RECEIPT\nTransaction 123\nAmount paid EUR 49\nTotal EUR 49") == .receipt)
        #expect(AttachmentCategoryClassifier.classify(filename: mixedName, mimeType: "application/pdf",
            subject: "Your documents", text: "ELECTRONIC TICKET\nPassenger Example\nFlight 123\nSeat 14C") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: mixedName, mimeType: "application/pdf",
            subject: "Your documents", text: "ELECTRONIC TICKET/RECEIPT\nBooking ABC123\nFlight 123\nDeparture 14:00\nArrival 16:00\nItinerary\nCheck-in") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "booking-invoice.pdf", mimeType: "application/pdf",
            subject: "Your booking is confirmed") == .invoice)
    }

    @Test func travelDocumentFieldsIdentifyPurposeWithoutConfusingHotelInvoices() {
        #expect(AttachmentCategoryClassifier.classify(filename: "document.pdf", mimeType: "application/pdf",
            subject: "Your documents", text: "CINEMA\nSCREEN 2\nROW 5\nSEAT 8\nEXAMPLE CINEMA\nMWST 10%") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "voucher.pdf", mimeType: "application/pdf",
            subject: "Ihre Unterlagen", text: "MIETWAGEN VOUCHER\nAbholung 01.06.2026\nRückgabe 08.06.2026\nRechnung erhalten Sie nach Rückgabe.") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "folio.pdf", mimeType: "application/pdf",
            subject: "Your booking", text: "INVOICE\nArrival 01.06.2026\nDeparture 03.06.2026\nFolio (Invoice)\nTotal EUR 240") == .invoice)
        #expect(AttachmentCategoryClassifier.classify(filename: "table.pdf", mimeType: "application/pdf",
            subject: "Document", text: "SEAT 8\nMWST 10%") == .uncategorized)
    }

    @Test func mixedLanguageFieldsAndReferencedInvoicesKeepTheirDocumentPurpose() {
        #expect(AttachmentCategoryClassifier.classify(filename: "scan.pdf", mimeType: "application/pdf",
            subject: "Document", text: "Kartenzahlung\nTOTAL CHF 12.00") == .receipt)
        #expect(AttachmentCategoryClassifier.classify(filename: "scan.pdf", mimeType: "application/pdf",
            subject: "Document", text: "Flugnummer 123\nSeat 12A") == .ticket)
        #expect(AttachmentCategoryClassifier.classify(filename: "scan.pdf", mimeType: "application/pdf",
            subject: "Document", text: "ZAHLUNGSBESTÄTIGUNG\nRechnungsnummer 123\nBetrag EUR 49") == .receipt)
        #expect(AttachmentCategoryClassifier.classify(filename: "scan.pdf", mimeType: "application/pdf",
            subject: "Document", text: "PAYMENT CONFIRMATION\nInvoice number 123\nTotal EUR 49") == .receipt)
        #expect(AttachmentCategoryClassifier.classify(filename: "scan.pdf", mimeType: "application/pdf",
            subject: "Document", text: "Cinema\nAbholung\nSeat 12A") == .uncategorized)
    }

    @Test func ambiguousOrAbsentEvidenceStaysUncategorized() {
        #expect(AttachmentCategoryClassifier.classify(filename: "document.pdf", mimeType: "application/pdf", subject: "Your files") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "document.pdf", mimeType: "application/pdf", subject: "Your invoice and receipt") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "invoice-receipt.pdf", mimeType: "application/pdf", subject: "Invoice") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "inv.pdf", mimeType: "application/pdf", subject: "Document") == .uncategorized)
        #expect(AttachmentCategoryClassifier.classify(filename: "Invitation123.pdf", mimeType: "application/pdf", subject: "Document") == .uncategorized)
    }
}
