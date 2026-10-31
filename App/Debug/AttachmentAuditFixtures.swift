#if DEBUG || TERN_PERFORMANCE
import Foundation

/// A valid one-page PDF assembled from synthetic ASCII text. No customer data.
enum AttachmentAuditFixtures {
    static let invoicePDF: Data = {
        let stream = "BT /F1 24 Tf 60 740 Td (INVOICE 2024-1042) Tj 0 -48 Td /F1 14 Tf (Mira Chen - Example Studio) Tj 0 -28 Td (Issued: October 15, 2024) Tj 0 -40 Td (Design services: EUR 480.00) Tj 0 -28 Td (Synthetic fixture - not payable) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }()
}
#endif
