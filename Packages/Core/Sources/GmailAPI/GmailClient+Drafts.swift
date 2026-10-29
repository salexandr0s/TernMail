import Foundation

/// A message to store as a draft or send, as raw RFC 5322 bytes with CRLF line endings.
public struct OutgoingMessage: Sendable, Equatable {
    public var raw: Data
    /// The thread a reply or forward joins. Nil starts a new thread.
    public var threadID: String?

    public init(raw: Data, threadID: String? = nil) {
        self.raw = raw
        self.threadID = threadID
    }
}

extension GmailClient {
    /// Messages up to this size go up in one `multipart/related` request and
    /// larger ones through a resumable session, as Google's upload guide advises.
    static let multipartUploadLimit = 5_000_000

    // MARK: Drafts

    public func drafts(query: String? = nil, pageToken: String? = nil, maxResults: Int = 500) async throws -> DraftListPage {
        var items = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try decode(await send(.get("drafts", items)))
    }

    public func draft(id: String, format: MessageFormat = .full) async throws -> GmailDraft {
        try decode(await send(.get("drafts/\(id)", [URLQueryItem(name: "format", value: format.rawValue)])))
    }

    /// `drafts.create`. A failure that leaves the outcome unknown, such as a
    /// timeout, may still have created the draft.
    public func createDraft(_ message: OutgoingMessage) async throws -> GmailDraft {
        try await upload(message, method: "POST", path: "drafts", metadata: DraftResource(id: nil, message: message))
    }

    /// `drafts.update`. Gmail replaces the draft's message, so the returned
    /// message has a new ID while the draft ID stays the same.
    public func updateDraft(id: String, with message: OutgoingMessage) async throws -> GmailDraft {
        try await upload(message, method: "PUT", path: "drafts/\(id)", metadata: DraftResource(id: id, message: message))
    }

    /// Sends a draft as last saved. Gmail deletes the draft, so sending it
    /// again fails with `notFound`.
    public func sendDraft(id: String) async throws -> GmailMessage {
        try decode(await send(.post("drafts/send", body: encode(DraftReference(id: id)))))
    }

    /// Replaces a draft's content and sends it in one call.
    public func sendDraft(id: String, with message: OutgoingMessage) async throws -> GmailMessage {
        try await upload(message, method: "POST", path: "drafts/send", metadata: DraftResource(id: id, message: message))
    }

    /// `drafts.delete`, which skips Trash.
    public func deleteDraft(id: String) async throws {
        _ = try await send(.delete("drafts/\(id)"))
    }

    // MARK: Uploads

    private func upload<T: Decodable>(
        _ message: OutgoingMessage,
        method: String,
        path: String,
        metadata: some Encodable
    ) async throws -> T {
        let json = try encode(metadata)
        if message.raw.count <= Self.multipartUploadLimit {
            let boundary = Self.boundary(avoiding: message.raw)
            let endpoint = Endpoint(
                base: .upload,
                method: method,
                path: path,
                query: [URLQueryItem(name: "uploadType", value: "multipart")],
                body: Self.multipartRelated(metadata: json, message: message.raw, boundary: boundary),
                contentType: "multipart/related; boundary=\(boundary)"
            )
            return try decode(await send(endpoint))
        }

        let start = Endpoint(
            base: .upload,
            method: method,
            path: path,
            query: [URLQueryItem(name: "uploadType", value: "resumable")],
            body: json,
            contentType: "application/json; charset=UTF-8",
            headers: [
                "X-Upload-Content-Type": "message/rfc822",
                "X-Upload-Content-Length": String(message.raw.count),
            ]
        )
        let (_, response) = try await send(start.urlRequest())
        // The session URI receives the access token, so it must be Google's.
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let session = URL(string: location),
              session.scheme == "https",
              session.host?.hasSuffix(".googleapis.com") == true
        else {
            throw GmailError.decoding("resumable upload session URI")
        }
        var request = URLRequest(url: session)
        request.httpMethod = "PUT"
        request.httpBody = message.raw
        request.setValue("message/rfc822", forHTTPHeaderField: "Content-Type")
        do {
            return try decode(await send(request).data)
        } catch GmailError.notFound, GmailError.http(status: 308, reason: _), GmailError.http(status: 410, reason: _) {
            // An expired or incomplete session, not a missing draft.
            throw GmailError.uploadSessionLost
        }
    }

    /// The metadata part first, then the message, as RFC 2046 lays out a multipart body.
    static func multipartRelated(metadata: Data, message: Data, boundary: String) -> Data {
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += metadata
        body += Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8)
        body += message
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    private static func boundary(avoiding message: Data) -> String {
        while true {
            let boundary = "tern-upload-\(UUID().uuidString)"
            if message.range(of: Data(boundary.utf8)) == nil { return boundary }
        }
    }
}

/// The Draft resource sent next to an upload. The message's content travels
/// in the upload itself.
private struct DraftResource: Encodable {
    struct Message: Encodable {
        let threadId: String?
    }

    let id: String?
    let message: Message

    init(id: String?, message: OutgoingMessage) {
        self.id = id
        self.message = Message(threadId: message.threadID)
    }
}

private struct DraftReference: Encodable {
    let id: String
}
