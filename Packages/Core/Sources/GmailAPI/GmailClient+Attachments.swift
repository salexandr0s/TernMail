import Foundation

extension GmailClient {
    /// `full` is needed for MIME structure; the field mask excludes every
    /// `body.data`, including small files normally embedded in the response.
    public func attachmentMetadata(ids: [String]) async throws -> [String: Result<GmailMessage, GmailError>] {
        let items = [URLQueryItem(name: "format", value: "full"),
                     URLQueryItem(name: "fields", value: Self.attachmentMetadataFields)]
        return try await batchDecode(ids) { .get("messages/\($0)", items) }
    }

    public func attachmentHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        var items = [URLQueryItem(name: "startHistoryId", value: startHistoryID),
                     URLQueryItem(name: "maxResults", value: "25")]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try decode(await send(.get("history", items)))
    }

    /// Explicit nested selectors are required by Google's partial responses.
    /// Indexing detects a deeper multipart tree and reports incomplete coverage.
    static let attachmentMetadataDepth = 20
    static var attachmentMetadataFields: String {
        let part = "partId,mimeType,filename,headers,body(attachmentId,size)"
        var fields = part
        for _ in 0..<attachmentMetadataDepth { fields = "\(part),parts(\(fields))" }
        return "id,threadId,historyId,labelIds,internalDate,payload(\(fields))"
    }
}
