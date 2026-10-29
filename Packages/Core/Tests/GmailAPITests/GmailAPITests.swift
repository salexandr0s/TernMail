import Foundation
import Testing
@testable import GmailAPI

@Suite struct GmailClientTests {
    @Test func batchMatchesPartsByContentIDAndRetriesOnlyRetryableParts() async throws {
        // First batch: parts out of order, "c" is gone, "b" is rate limited, "d" has no part.
        let first = batchResponse([
            (2, 404, #"{"error":{"code":404,"message":"Not Found"}}"#),
            (0, 200, #"{"id":"a","threadId":"t1","labelIds":["INBOX"]}"#),
            (1, 429, #"{"error":{"code":429}}"#),
        ])
        // Retry round carries only "b" and "d", renumbered from zero.
        let retry = batchResponse([
            (1, 200, #"{"id":"d","threadId":"t3"}"#),
            (0, 200, #"{"id":"b","threadId":"t2"}"#),
        ])
        let transport = StubTransport([first, retry])
        let client = GmailClient(tokens: StubTokens(), transport: transport, retryDelays: [.zero])

        let results = try await client.messages(ids: ["a", "b", "c", "d"], format: .minimal)

        #expect(try results["a"]?.get().labelIds == ["INBOX"])
        #expect(try results["b"]?.get().threadId == "t2")
        #expect(results["c"].flatMap(failure) == .notFound)
        #expect(try results["d"]?.get().threadId == "t3")

        let requests = await transport.requests
        #expect(requests.count == 2)
        let retryBody = String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(retryBody.contains("/messages/b?"))
        #expect(retryBody.contains("/messages/d?"))
        #expect(!retryBody.contains("/messages/a?"))
        #expect(!retryBody.contains("/messages/c?"))
    }

    @Test func unauthorizedIsRetriedOnceWithForcedRefresh() async throws {
        let profile = #"{"emailAddress":"user@example.com","historyId":"42"}"#
        let tokens = StubTokens()
        let transport = StubTransport([
            .init(status: 401, body: "{}"),
            .init(status: 200, body: profile),
            .init(status: 401, body: "{}"),
            .init(status: 401, body: "{}"),
        ])
        let client = GmailClient(tokens: tokens, transport: transport)

        #expect(try await client.profile().historyId == "42")
        await #expect(throws: GmailError.unauthorized) { try await client.profile() }

        let requests = await transport.requests
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer token-0", "Bearer token-1", "Bearer token-1", "Bearer token-2",
        ])
    }

    @Test func rateLimitReasonsAreRetryable() {
        let rateLimited = Data(#"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded"}]}}"#.utf8)
        let forbidden = Data(#"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}]}}"#.utf8)

        #expect(GmailError(status: 403, body: rateLimited) == .rateLimited)
        #expect(GmailError(status: 403, body: rateLimited).isRetryable)
        #expect(GmailError(status: 403, body: forbidden) == .http(status: 403, reason: "insufficientPermissions"))
        #expect(!GmailError(status: 403, body: forbidden).isRetryable)
    }

    @Test func queryEscapesPlusSigns() async throws {
        let transport = StubTransport([.init(status: 200, body: "{}")])
        let client = GmailClient(tokens: StubTokens(), transport: transport)

        _ = try await client.listMessages(query: "from:a+b@example.com newer_than:30d")

        let query = try #require(await transport.requests.first?.url?.query(percentEncoded: true))
        #expect(query.contains("a%2Bb@example.com"))
        #expect(!query.contains("+"))
    }

    @Test func historyPageDecodesEveryChangeType() throws {
        let json = #"""
        {
          "history": [
            {"id": "101", "messagesAdded": [{"message": {"id": "m1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"]}}]},
            {"id": "102", "labelsRemoved": [{"message": {"id": "m1", "threadId": "t1"}, "labelIds": ["UNREAD"]}]},
            {"id": "103", "labelsAdded": [{"message": {"id": "m2", "threadId": "t2"}, "labelIds": ["STARRED"]}]},
            {"id": "104", "messagesDeleted": [{"message": {"id": "m3", "threadId": "t3"}}]}
          ],
          "historyId": "104"
        }
        """#
        let page = try JSONDecoder().decode(HistoryPage.self, from: Data(json.utf8))

        #expect(page.historyId == "104")
        #expect(page.history?[0].messagesAdded?.first?.message.labelIds == ["INBOX", "UNREAD"])
        #expect(page.history?[1].labelsRemoved?.first?.labelIds == ["UNREAD"])
        #expect(page.history?[2].labelsAdded?.first?.message.id == "m2")
        #expect(page.history?[3].messagesDeleted?.first?.message.id == "m3")
    }
}

@Suite struct DraftUploadTests {
    private let draftJSON = #"{"id":"d1","message":{"id":"m1","threadId":"t1","labelIds":["DRAFT"]}}"#

    @Test func smallDraftsUploadAsMultipartRelated() async throws {
        let transport = StubTransport([.init(status: 200, body: draftJSON)])
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let raw = Data("Subject: Hi\r\n\r\nBody\r\n".utf8)

        let draft = try await client.createDraft(OutgoingMessage(raw: raw, threadID: "t1"))

        #expect(draft.id == "d1")
        #expect(draft.message?.id == "m1")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/upload/gmail/v1/users/me/drafts")
        #expect(request.url?.query == "uploadType=multipart")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.split(separator: "=").last.map(String.init))
        #expect(contentType == "multipart/related; boundary=\(boundary)")
        let expected = "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
            + #"{"message":{"threadId":"t1"}}"#
            + "\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n"
            + "Subject: Hi\r\n\r\nBody\r\n"
            + "\r\n--\(boundary)--\r\n"
        #expect(request.httpBody == Data(expected.utf8))
    }

    @Test func updateAndSendCarryTheDraftID() async throws {
        let sent = #"{"id":"m2","threadId":"t1","labelIds":["SENT"]}"#
        let transport = StubTransport([
            .init(status: 200, body: draftJSON),
            .init(status: 200, body: sent),
            .init(status: 200, body: sent),
        ])
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let message = OutgoingMessage(raw: Data("Subject: Hi\r\n\r\nBody\r\n".utf8))

        _ = try await client.updateDraft(id: "d1", with: message)
        _ = try await client.sendDraft(id: "d1", with: message)
        #expect(try await client.sendDraft(id: "d1").labelIds == ["SENT"])

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "POST", "POST"])
        #expect(requests.map { $0.url?.path } == [
            "/upload/gmail/v1/users/me/drafts/d1",
            "/upload/gmail/v1/users/me/drafts/send",
            "/gmail/v1/users/me/drafts/send",
        ])
        for request in requests.prefix(2) {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains(#""id":"d1""#))
            #expect(body.contains(#""message":{}"#))
        }
        #expect(requests[2].httpBody == Data(#"{"id":"d1"}"#.utf8))
    }

    @Test func largeDraftsUseAResumableSession() async throws {
        let session = "https://gmail.googleapis.com/upload/gmail/v1/users/me/drafts?uploadType=resumable&upload_id=abc"
        let transport = StubTransport([
            .init(status: 200, headers: ["Location": session], body: ""),
            .init(status: 200, body: draftJSON),
        ])
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let raw = Data(repeating: UInt8(ascii: "a"), count: GmailClient.multipartUploadLimit + 1)

        #expect(try await client.createDraft(OutgoingMessage(raw: raw)).id == "d1")

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.query == "uploadType=resumable")
        #expect(requests[0].value(forHTTPHeaderField: "X-Upload-Content-Type") == "message/rfc822")
        #expect(requests[0].value(forHTTPHeaderField: "X-Upload-Content-Length") == String(raw.count))
        #expect(requests[0].httpBody == Data(#"{"message":{}}"#.utf8))
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[1].url?.absoluteString == session)
        #expect(requests[1].httpBody == raw)
    }

    @Test func resumableSessionsOutsideGoogleAreRefused() async throws {
        let transport = StubTransport([
            .init(status: 200, headers: ["Location": "https://uploads.example.com/session"], body: ""),
        ])
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let raw = Data(count: GmailClient.multipartUploadLimit + 1)

        await #expect(throws: GmailError.self) { try await client.createDraft(OutgoingMessage(raw: raw)) }
        #expect(await transport.requests.count == 1)
    }

    @Test func aLostUploadSessionIsRetryableNotAMissingDraft() async throws {
        let transport = StubTransport([
            .init(status: 200, headers: ["Location": "https://gmail.googleapis.com/upload/session"], body: ""),
            .init(status: 404, body: "{}"),
        ])
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let raw = Data(count: GmailClient.multipartUploadLimit + 1)

        await #expect(throws: GmailError.uploadSessionLost) {
            try await client.sendDraft(id: "d1", with: OutgoingMessage(raw: raw))
        }
        #expect(GmailError.uploadSessionLost.isRetryable)
    }

    @Test func attachmentsDecodeFromBase64URL() async throws {
        let transport = StubTransport([.init(status: 200, body: #"{"size":3,"data":"-_8"}"#)])
        let client = GmailClient(tokens: StubTokens(), transport: transport)

        #expect(try await client.attachment(messageID: "m1", attachmentID: "a1") == Data([0xFB, 0xFF]))
        #expect(await transport.requests.first?.url?.path == "/gmail/v1/users/me/messages/m1/attachments/a1")
    }
}

// MARK: Helpers

private func failure<T>(_ result: Result<T, GmailError>) -> GmailError? {
    if case .failure(let error) = result { return error }
    return nil
}

/// A `/batch` response whose parts are (request index, status, JSON body).
private func batchResponse(_ parts: [(Int, Int, String)]) -> StubTransport.Response {
    var body = ""
    for (index, status, json) in parts {
        body += "--resp\r\nContent-Type: application/http\r\nContent-ID: <response-item-\(index)>\r\n\r\n"
        body += "HTTP/1.1 \(status) Status\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
        body += json + "\r\n"
    }
    body += "--resp--\r\n"
    return .init(status: 200, headers: ["Content-Type": "multipart/mixed; boundary=resp"], body: body)
}

private actor StubTransport: HTTPTransport {
    struct Response {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: String
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty, let url = request.url else { throw URLError(.badServerResponse) }
        let next = responses.removeFirst()
        guard let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers) else {
            throw URLError(.badServerResponse)
        }
        return (Data(next.body.utf8), response)
    }
}

/// Returns "token-N", where N counts forced refreshes so far.
private actor StubTokens: AccessTokenProvider {
    private var refreshes = 0

    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshes += 1 }
        return "token-\(refreshes)"
    }
}
