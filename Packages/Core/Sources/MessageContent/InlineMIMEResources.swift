import Foundation
import GmailAPI

public struct InlineMIMEResource: Sendable, Equatable {
    public let contentID: String
    public let partID: String
    public let mimeType: String
    public let data: Data
    public init(contentID: String, partID: String, mimeType: String, data: Data) {
        self.contentID = contentID; self.partID = partID; self.mimeType = mimeType; self.data = data
    }
}

public struct InlineMIMEPart: Sendable, Equatable {
    public let contentID: String
    public let partID: String
    public let mimeType: String
    public let size: Int
    public let attachmentID: String?
    public let inlineData: Data?
}

public enum InlineMIMEResources {
    public static let maximumCount = 32
    public static let maximumResourceBytes = 5 * 1_024 * 1_024
    public static let maximumMessageBytes = 20 * 1_024 * 1_024
    public static let allowedTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    public static func normalizedContentID(_ value: String) -> String? {
        var id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<"), id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
        guard !id.isEmpty, id.utf8.count <= 1_024, !id.contains("<"), !id.contains(">"),
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return id
    }

    /// Attached messages and attachment containers cannot supply this message's CID map.
    public static func parts(of message: GmailMessage) -> [InlineMIMEPart] {
        var result: [InlineMIMEPart] = []
        var seen = Set<String>()
        var total = 0
        func visit(_ part: MessagePart, depth: Int) {
            guard depth <= 30, result.count < maximumCount else { return }
            let mime = (part.mimeType ?? "").lowercased()
            if mime == "message/rfc822" { return }
            if mime.hasPrefix("multipart/") {
                guard !MIMEParts.isAttachment(part) else { return }
                for child in (part.parts ?? []).prefix(256) { visit(child, depth: depth + 1) }
                return
            }
            guard allowedTypes.contains(mime), let raw = part.header("Content-ID"), let cid = normalizedContentID(raw),
                  !seen.contains(cid), let partID = part.partId,
                  (part.body?.size ?? 0) <= maximumResourceBytes,
                  (part.body?.data?.utf8.count ?? 0) <= (maximumResourceBytes * 4 / 3 + 8) else { return }
            let inline = part.body?.decodedData
            let size = max(part.body?.size ?? inline?.count ?? 0, inline?.count ?? 0)
            guard size > 0, size <= maximumResourceBytes, total <= maximumMessageBytes - size,
                  inline != nil || part.body?.attachmentId != nil else { return }
            seen.insert(cid); total += size
            result.append(InlineMIMEPart(contentID: cid, partID: partID, mimeType: mime, size: size,
                attachmentID: part.body?.attachmentId, inlineData: inline))
        }
        if let payload = message.payload { visit(payload, depth: 0) }
        return result
    }
}

/// One immutable WebKit capability. A different message gets a different scope.
public struct InlineResourceMap: Sendable, Equatable {
    public static let scheme = "tern-message"
    public let scope: String
    public let resources: [String: InlineMIMEResource]

    public init(scope: String = UUID().uuidString.lowercased(), resources: [InlineMIMEResource] = []) {
        self.scope = scope.lowercased()
        var accepted: [String: InlineMIMEResource] = [:]
        var total = 0
        for resource in resources.prefix(InlineMIMEResources.maximumCount) {
            guard let cid = InlineMIMEResources.normalizedContentID(resource.contentID), accepted[cid] == nil,
                  InlineMIMEResources.allowedTypes.contains(resource.mimeType), !resource.data.isEmpty,
                  resource.data.count <= InlineMIMEResources.maximumResourceBytes,
                  total <= InlineMIMEResources.maximumMessageBytes - resource.data.count else { continue }
            accepted[cid] = resource; total += resource.data.count
        }
        self.resources = accepted
    }

    public func url(for contentID: String) -> URL? {
        guard let cid = InlineMIMEResources.normalizedContentID(contentID), resources[cid] != nil else { return nil }
        let encoded = Data(cid.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "\(Self.scheme)://\(scope)/\(encoded)")
    }

    public func resource(for url: URL) -> InlineMIMEResource? {
        guard url.scheme == Self.scheme, url.host == scope, url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.split(separator: "/").count == 1 else { return nil }
        var value = String(url.path.dropFirst()).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: value), let cid = String(data: bytes, encoding: .utf8), self.url(for: cid) == url else { return nil }
        return resources[cid]
    }
}
