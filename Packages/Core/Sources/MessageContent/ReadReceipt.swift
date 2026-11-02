import Foundation
import GmailAPI

/// A recipient's report of message disposition. Even `displayed` is a claim
/// from their mail client, not proof that the person read the message.
public struct ReadReceipt: Sendable, Equatable {
    public enum Disposition: String, Sendable, Codable {
        case displayed, dispatched, processed, deleted
    }

    public let originalMessageID: String
    public let recipient: String
    public let disposition: Disposition

    public init(originalMessageID: String, recipient: String, disposition: Disposition) {
        self.originalMessageID = originalMessageID
        self.recipient = recipient
        self.disposition = disposition
    }
}

public enum ReadReceiptParser {
    public static let maximumReportBytes = 65_536

    public static func isCandidate(_ message: GmailMessage) -> Bool {
        guard let payload = message.payload,
              let contentType = payload.header("Content-Type"),
              contentType.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "multipart/report",
              MIMEReader.parameters(of: contentType)["report-type"]?.lowercased() == "disposition-notification"
        else { return false }
        return true
    }

    /// Reports can be returned as a separately fetched part by Gmail. Only
    /// direct children count: an attached or forwarded report is not a receipt.
    public static func requiredAttachmentID(of message: GmailMessage) -> String? {
        guard let part = reportPart(in: message), part.body?.decodedData == nil,
              (part.body?.size ?? 0) <= maximumReportBytes else { return nil }
        return part.body?.attachmentId
    }

    public static func receipt(in message: GmailMessage, attachments: [String: Data] = [:]) -> ReadReceipt? {
        guard let part = reportPart(in: message),
              let data = part.body?.decodedData ?? part.body?.attachmentId.flatMap({ attachments[$0] }),
              data.count <= maximumReportBytes,
              let text = String(data: data, encoding: .utf8),
              let fields = fields(in: text),
              let originalID = fields["original-message-id"], validMessageID(originalID),
              let recipientField = fields["final-recipient"],
              let recipient = address(inRecipientField: recipientField),
              let dispositionField = fields["disposition"]
        else { return nil }

        let parts = dispositionField.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let mode = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let modes = mode.split(separator: "/", omittingEmptySubsequences: false)
        guard modes.count == 2, ["manual-action", "automatic-action"].contains(String(modes[0])),
              ["mdn-sent-manually", "mdn-sent-automatically"].contains(String(modes[1])) else { return nil }
        // An error modifier makes even a displayed report unsuitable as confirmation.
        let outcome = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        guard !outcome.contains("/"), let disposition = ReadReceipt.Disposition(rawValue: outcome) else { return nil }
        return ReadReceipt(originalMessageID: originalID, recipient: recipient, disposition: disposition)
    }

    public static func validMessageID(_ value: String) -> Bool {
        guard value.utf8.count <= 998, value.hasPrefix("<"), value.hasSuffix(">") else { return false }
        let inside = value.dropFirst().dropLast()
        return inside.contains("@") && !inside.isEmpty && inside.allSatisfy {
            $0.isASCII && !$0.isWhitespace && !$0.isNewline && !"<>".contains($0)
                && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
    }

    private static func reportPart(in message: GmailMessage) -> MessagePart? {
        guard isCandidate(message), let payload = message.payload,
              (payload.mimeType ?? "multipart/report").lowercased() == "multipart/report" else { return nil }
        let reports = (payload.parts ?? []).filter { $0.mimeType?.lowercased() == "message/disposition-notification" }
        guard reports.count == 1 else { return nil }
        return reports.first
    }

    private static func address(inRecipientField value: String) -> String? {
        let parts = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "rfc822" else { return nil }
        let address = EmailAddress(address: parts[1].trimmingCharacters(in: .whitespaces))
        return address.isValid ? address.normalized : nil
    }

    private static func fields(in text: String) -> [String: String]? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r"), !normalized.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }) else { return nil }
        var lines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let last = lines.indices.last else { return nil }
                lines[last] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        var result: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  result[name] == nil else { return nil }
            result[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
