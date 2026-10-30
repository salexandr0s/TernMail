import Foundation
import PDFKit
import SyncEngine

struct AttachmentText: Sendable {
    struct Page: Sendable, Encodable {
        let number: Int
        let text: String
    }
    let text: String
    let pages: [Page]
    let truncated: Bool
    let limitations: [String]
}

enum AttachmentTextReader {
    static let characterLimit = 60_000
    static let pageLimit = 40

    static func extract(_ data: Data, mimeType: String, filename: String) throws -> AttachmentText {
        guard data.count <= AssistantMailLimits.attachmentBytes else { throw AssistantMailError.attachmentTooLarge }
        try Task.checkCancellation()
        let type = mimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if type == "application/pdf" || (type == "application/octet-stream" && filename.lowercased().hasSuffix(".pdf")) {
            guard let document = PDFDocument(data: data), !document.isLocked else { throw ReadError.unreadablePDF }
            var pages: [AttachmentText.Page] = []
            var remaining = characterLimit
            var unreadable = 0
            var truncated = document.pageCount > pageLimit
            for index in 0..<min(pageLimit, document.pageCount) {
                try Task.checkCancellation()
                guard let text = document.page(at: index)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    unreadable += 1
                    continue
                }
                let limited = String(text.prefix(remaining))
                if text.count > remaining { truncated = true }
                remaining -= limited.count
                if !limited.isEmpty { pages.append(.init(number: index + 1, text: limited)) }
                if remaining == 0 {
                    truncated = truncated || index + 1 < document.pageCount
                    break
                }
            }
            guard !pages.isEmpty else { throw ReadError.noPDFText }
            let limitations = unreadable > 0 ? ["\(unreadable) inspected PDF pages had no readable text. OCR is not available."] : []
            return AttachmentText(text: pages.map(\.text).joined(separator: "\n\n"), pages: pages, truncated: truncated, limitations: limitations)
        }
        let plain = ["text/plain", "text/csv", "text/tab-separated-values", "text/markdown", "application/json", "application/xml", "text/xml"]
        guard plain.contains(type) else { throw ReadError.unsupported }
        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding), !text.contains("\0") else { throw ReadError.unreadableText }
        return AttachmentText(text: String(text.prefix(characterLimit)), pages: [], truncated: text.count > characterLimit, limitations: [])
    }

    enum ReadError: Error, LocalizedError {
        case unsupported, unreadablePDF, noPDFText, unreadableText
        var errorDescription: String? {
            switch self {
            case .unsupported: "The assistant can read plain-text files and PDFs with selectable text. This file format is not supported."
            case .unreadablePDF: "This PDF is locked or could not be opened."
            case .noPDFText: "This PDF has no readable text in the inspected pages. OCR is not available."
            case .unreadableText: "This file could not be decoded as UTF-8 or UTF-16 text."
            }
        }
    }
}
