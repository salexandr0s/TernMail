import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    /// Reads only eligible image parts. Declared and actual bytes share the
    /// same caps; MIME resource writes remain behind the engine's write gate.
    func inlineResources(in message: GmailMessage) async throws -> [MIMEInlineResourceRecord] {
        var result: [MIMEInlineResourceRecord] = []
        var total = 0
        for part in InlineMIMEResources.parts(of: message) {
            try Task.checkCancellation()
            let bytes: Data
            if let inline = part.inlineData { bytes = inline }
            else if let id = part.attachmentID { bytes = try await gmail.attachment(messageID: message.id, attachmentID: id) }
            else { continue }
            guard !bytes.isEmpty, bytes.count <= InlineMIMEResources.maximumResourceBytes,
                  total <= InlineMIMEResources.maximumMessageBytes - bytes.count else { continue }
            total += bytes.count
            result.append(MIMEInlineResourceRecord(accountID: accountID, messageID: message.id,
                contentID: part.contentID, partID: part.partID, mimeType: part.mimeType, data: bytes))
        }
        return result
    }
}
