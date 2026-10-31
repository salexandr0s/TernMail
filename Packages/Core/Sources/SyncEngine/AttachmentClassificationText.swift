import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads only a bounded part of a document. Text and images stay on this Mac;
/// the extracted text is used for classification and is not retained or logged.
enum AttachmentClassificationText {
    static let maximumBytes = 10 * 1_024 * 1_024
    static let maximumPages = 3
    static let maximumCharacters = 12_000
    static let maximumImageDimension = 1_800

    static func extract(_ data: Data, mimeType: String, filename: String) throws -> String {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { return "" }
        let type = mimeType.lowercased().split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suffix = (filename as NSString).pathExtension.lowercased()
        if type == "application/pdf" || suffix == "pdf" {
            return try pdfText(data)
        }
        if type.hasPrefix("image/") || ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif"].contains(suffix) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumImageDimension,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return "" }
            return try recognize(image)
        }
        guard ["text/plain", "text/csv", "text/markdown"].contains(type) || ["txt", "csv", "md"].contains(suffix) else { return "" }
        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding), !text.contains("\0") else { return "" }
        return String(text.prefix(maximumCharacters))
    }

    private static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked else { return "" }
        var output = ""
        for index in 0..<min(document.pageCount, maximumPages) {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 24 {
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { continue }
                let scale = CGFloat(maximumImageDimension) / max(bounds.width, bounds.height)
                let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                if let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = try recognize(image)
                }
            }
            let remaining = maximumCharacters - output.count
            guard remaining > 0 else { break }
            if !output.isEmpty { output += "\n" }
            output += text.prefix(max(0, maximumCharacters - output.count))
        }
        try Task.checkCancellation()
        return output
    }

    private static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "de-DE"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            try Task.checkCancellation()
            return ""
        }
        try Task.checkCancellation()
        return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").prefix(maximumCharacters))
    }
}
