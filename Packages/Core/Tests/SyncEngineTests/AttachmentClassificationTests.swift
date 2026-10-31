import CoreGraphics
import CoreText
import Foundation
import GmailAPI
import ImageIO
import MailStore
import Testing
import UniformTypeIdentifiers
@testable import SyncEngine

@Suite struct AttachmentClassificationTests {
    @Test func opaquePDFAndScansClassifyAcrossBoundedPassesAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "classification.sqlite")
        let cache = try MailCache.open(at: url)
        let gmail = FakeGmail()
        let invoice = try documentPDF(lines: ["INVOICE", "Invoice number 1042", "Amount due EUR 480.00"])
        let receipt = try documentImage(lines: ["RECEIPT", "Payment received", "Total paid EUR 42.00"])
        let ticket = try documentPDF(lines: ["BOARDING PASS", "Flight OS 123", "Seat 12A", "Vienna to London"], scanned: true)
        for (id, data, mime, suffix) in [
            ("a", invoice, "application/pdf", "pdf"),
            ("b", receipt, "image/png", "png"),
            ("c", ticket, "application/pdf", "pdf"),
        ] {
            try await seed(cache, id: id, mime: mime, filename: "document.\(suffix)", size: data.count)
            await gmail.setAttachment(id, data: data)
        }
        try await seed(cache, id: "foreign", accountID: "b", mime: "application/pdf", filename: "document.pdf", size: invoice.count)
        let engine = classificationEngine(cache, gmail)
        #expect(try await engine.classifyAttachments(limit: 2) == 2)
        #expect(await gmail.attachmentRequests.count == 2)
        await engine.stop()
        let reopened = try MailCache.open(at: url)
        let restarted = classificationEngine(reopened, gmail)
        #expect(try await restarted.classifyAttachments() == 1)
        #expect(try await restarted.classifyAttachments() == 0)
        let items = try await reopened.attachmentLibrary(query: .init(accountIDs: ["a"])).items
        #expect(Set(items.map(\.category)) == [.invoice, .receipt, .ticket])
        #expect(items.allSatisfy { $0.categorySource == .content })
        #expect(await gmail.attachmentRequests.count == 3)
        #expect(try await reopened.attachmentLibrary(query: .init(accountIDs: ["b"])).items.first?.category == .uncategorized)
    }

    @Test func unreadableFilesCheckpointAndTransportFailuresWaitWithoutBlockingOthers() async throws {
        let cache = try MailCache.inMemory()
        let gmail = FakeGmail()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        for id in ["broken", "failed", "healthy", "missing"] {
            try await seed(cache, id: id, mime: "application/pdf", filename: "document.pdf", size: 100)
        }
        await gmail.setAttachment("broken", data: Data("not a pdf".utf8))
        await gmail.setMetadataErrors(["failed": .transport(.networkConnectionLost)])
        await gmail.setAttachment("healthy", data: try documentPDF(lines: ["RECEIPT", "Total paid EUR 45.00"]))
        try await seed(cache, id: "oversized", mime: "application/pdf", filename: "document.pdf", size: 20 * 1_024 * 1_024)
        let engine = classificationEngine(cache, gmail, now: timestamp)
        #expect(try await engine.classifyAttachments() == 3)
        #expect(try await engine.classifyAttachments() == 1)
        #expect(try await engine.classifyAttachments() == 0)
        let later = try await cache.pendingAttachmentClassifications(accountID: "a", now: timestamp.addingTimeInterval(301))
        #expect(later.map(\.messageID) == ["failed"])
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], category: .receipt)).totalCount == 1)
        #expect(!(await gmail.attachmentRequests).contains("oversized"))
    }

    @Test func documentContentsDisambiguateFilesSharingBookingSubject() async throws {
        let cache = try MailCache.inMemory()
        let gmail = FakeGmail()
        let invoice = try documentPDF(lines: ["INVOICE", "Invoice number 1042", "Amount due EUR 480.00"])
        let ticket = try documentPDF(lines: ["BOARDING PASS", "Flight OS 123", "Seat 12A"])
        let attachments = [
            AttachmentRecord(accountID: "a", messageID: "booking", partID: "1", attachmentID: "invoice",
                filename: "download.pdf", mimeType: "application/pdf", size: invoice.count, isInline: false),
            AttachmentRecord(accountID: "a", messageID: "booking", partID: "2", attachmentID: "ticket",
                filename: "document.pdf", mimeType: "application/pdf", size: ticket.count, isInline: false),
        ]
        let message = MessageRecord(accountID: "a", id: "booking", threadID: "booking", historyID: 1,
            date: Date(timeIntervalSince1970: 1), snippet: "", sender: "Synthetic", recipients: "", cc: nil,
            subject: "Your booking confirmation", sizeEstimate: invoice.count + ticket.count)
        try await cache.write { try $0.replaceLibraryAttachments(attachments, message: message, labelIDs: []) }
        await gmail.setAttachment("invoice", data: invoice)
        await gmail.setAttachment("ticket", data: ticket)
        try await seed(cache, id: "receipt-subject", mime: "application/pdf", filename: "download.pdf",
            size: invoice.count, subject: "Your receipt")
        await gmail.setAttachment("receipt-subject", data: invoice)
        try await seed(cache, id: "unreadable", mime: "application/pdf", filename: "download.pdf",
            size: 100, subject: "Your receipt")
        await gmail.setAttachment("unreadable", data: Data("not a pdf".utf8))
        let ambiguous = try documentPDF(lines: ["INVOICE", "RECEIPT", "Combined document"])
        try await seed(cache, id: "ambiguous", mime: "application/pdf", filename: "download.pdf",
            size: ambiguous.count, subject: "Your booking confirmation")
        await gmail.setAttachment("ambiguous", data: ambiguous)
        try await seed(cache, id: "missing", mime: "application/pdf", filename: "download.pdf",
            size: 100, subject: "Your receipt")
        try await seed(cache, id: "named", mime: "application/pdf", filename: "invoice-1042.pdf",
            size: invoice.count, subject: "Your booking confirmation")
        try await seed(cache, id: "manual", mime: "application/pdf", filename: "document.pdf",
            size: invoice.count, subject: "Your booking confirmation")
        try await cache.write { try $0.setAttachmentCategory(.uncategorized, accountID: "a", messageID: "manual", partID: "1") }
        let initial = try await cache.attachmentLibrary(query: .init(accountIDs: ["a"])).items
        #expect(initial.filter { $0.messageID == "booking" }.allSatisfy { $0.category == .ticket && $0.categorySource == .subject })
        let engine = classificationEngine(cache, gmail)
        #expect(try await engine.classifyAttachments() == 3)
        #expect(try await engine.classifyAttachments() == 3)
        #expect(try await engine.classifyAttachments() == 0)
        let items = try await cache.attachmentLibrary(query: .init(accountIDs: ["a"])).items
        #expect(items.first { $0.messageID == "booking" && $0.partID == "1" }?.category == .invoice)
        #expect(items.first { $0.messageID == "booking" && $0.partID == "2" }?.category == .ticket)
        #expect(items.first { $0.messageID == "receipt-subject" }?.category == .invoice)
        #expect(items.first { $0.messageID == "unreadable" }?.category == .receipt)
        #expect(items.first { $0.messageID == "missing" }?.category == .receipt)
        #expect(items.first { $0.messageID == "ambiguous" }?.category == .uncategorized)
        #expect(items.first { $0.messageID == "manual" }?.category == .uncategorized)
        #expect(Set(await gmail.attachmentRequests) == ["invoice", "ticket", "receipt-subject", "unreadable", "missing", "ambiguous"])
    }

    @Test func manualChoiceWinsWhenDownloadCompletesAfterCorrection() async throws {
        let cache = try MailCache.inMemory()
        let gmail = FakeGmail()
        try await seed(cache, id: "held", mime: "text/plain", filename: "document.txt", size: 100)
        await gmail.add(try inlineDocument("held", text: "INVOICE\nAmount due EUR 42.00"))
        await gmail.holdNextMetadata()
        let engine = classificationEngine(cache, gmail)
        let pending = Task { try await engine.classifyAttachments() }
        while !(await gmail.isHoldingMetadata) { await Task.yield() }
        try await cache.write { try $0.setAttachmentCategory(.uncategorized, accountID: "a", messageID: "held", partID: "1") }
        await gmail.releaseMetadata()
        _ = try await pending.value
        let item = try #require(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"])).items.first)
        #expect(item.category == .uncategorized)
        #expect(item.categorySource == .manual)
    }

    @Test func stopWaitsForInFlightDownloadAndDoesNotCommitClassification() async throws {
        let cache = try MailCache.inMemory()
        let gmail = FakeGmail()
        try await seed(cache, id: "held", mime: "text/plain", filename: "document.txt", size: 100)
        await gmail.add(try inlineDocument("held", text: "INVOICE\nAmount due EUR 42.00"))
        await gmail.holdNextMetadata()
        let engine = classificationEngine(cache, gmail)
        let pending = Task { try await engine.classifyAttachments() }
        while !(await gmail.isHoldingMetadata) { await Task.yield() }
        let stopping = Task { await engine.stop() }
        while !(await engine.isStopped) { await Task.yield() }
        await gmail.releaseMetadata()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a").count == 1)
    }
}

private func classificationEngine(_ cache: MailCache, _ gmail: FakeGmail, now: Date = Date()) -> SyncEngine {
    SyncEngine(accountID: "a", sender: .init(address: "user@example.invalid"),
        outgoingDirectory: FileManager.default.temporaryDirectory, gmail: gmail, cache: cache,
        sendsAutomatically: false, now: { now })
}

private func seed(_ cache: MailCache, id: String, accountID: String = "a", mime: String, filename: String, size: Int,
                  subject: String = "Documents") async throws {
    let attachment = AttachmentRecord(accountID: accountID, messageID: id, partID: "1", attachmentID: id,
        filename: filename, mimeType: mime, size: size, isInline: false)
    let message = MessageRecord(accountID: accountID, id: id, threadID: id, historyID: 1,
        date: Date(timeIntervalSince1970: 1), snippet: "", sender: "Synthetic", recipients: "", cc: nil,
        subject: subject, sizeEstimate: size)
    try await cache.write { try $0.replaceLibraryAttachments([attachment], message: message, labelIDs: []) }
}

private func inlineDocument(_ id: String, text: String) throws -> GmailMessage {
    let encoded = Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return try JSONDecoder().decode(GmailMessage.self, from: Data(#"""
        {"id":"\#(id)","threadId":"\#(id)","payload":{"mimeType":"multipart/mixed","parts":[{"partId":"1","filename":"document.txt","mimeType":"text/plain","body":{"data":"\#(encoded)","size":\#(text.utf8.count)}}]}}
        """#.utf8))
}

private func documentImage(lines: [String]) throws -> Data {
    let image = try renderedDocument(lines: lines)
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func renderedDocument(lines: [String]) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 1200, height: 1000, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1000))
    draw(lines: lines, in: context)
    return try #require(context.makeImage())
}

private func documentPDF(lines: [String], scanned: Bool = false) throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data))
    var bounds = CGRect(x: 0, y: 0, width: 1200, height: 1000)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    if scanned { context.draw(try renderedDocument(lines: lines), in: bounds) }
    else { draw(lines: lines, in: context) }
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

private func draw(lines: [String], in context: CGContext) {
    let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
    for (index, text) in lines.enumerated() {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 60, y: 850 - index * 90)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}
