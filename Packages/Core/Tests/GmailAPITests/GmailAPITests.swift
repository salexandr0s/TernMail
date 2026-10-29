import Foundation
import Testing
@testable import GmailAPI

@Suite struct GmailClientTests {
    @Test func externalMessagePartUsesTheMessageScopedEndpointAndDecodesData() async throws {
        let transport = StubTransport([.init(status: 200, body: #"{"data":"Y2Fmw6k","size":5}"#)])
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let data = try await client.attachment(messageID: "m1", attachmentID: "part1")
        #expect(String(data: data, encoding: .utf8) == "café")
        #expect(await transport.requests.first?.url?.path == "/gmail/v1/users/me/messages/m1/attachments/part1")
    }

    @Test func unauthorizedBatchPartsRefreshOnceWithoutResendingSuccesses() async throws {
        let transport = StubTransport([
            batchResponse([(0, 200, #"{"id":"a","threadId":"t1"}"#), (1, 401, "{}")]),
            batchResponse([(0, 401, "{}")]),
        ])
        let client = GmailClient(tokens: StubTokens(), transport: transport, retryDelays: [.zero])
        let results = try await client.messages(ids: ["a", "b"], format: .minimal)
        #expect(try results["a"]?.get().id == "a")
        #expect(results["b"].flatMap(failure) == .unauthorized)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-0", "Bearer token-1"])
        let retryBody = String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(!retryBody.contains("/messages/a?"))
    }

    @Test func batchUsesCompleteRequestLinesAndIgnoresBoundaryTextInJSON() async throws {
        let transport = StubTransport([batchResponse([
            (0, 200, #"{"id":"a","threadId":"t1","snippet":"text --resp inside JSON"}"#),
        ])])
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let results = try await client.messages(ids: ["a"], format: .metadata)
        #expect(try results["a"]?.get().snippet == "text --resp inside JSON")
        let body = String(decoding: try #require(await transport.requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("GET /gmail/v1/users/me/messages/a?format=metadata HTTP/1.1\r\n"))
    }

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

    @Test(arguments: ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"])
    func rateLimitReasonsAreRetryable(_ reason: String) {
        let rateLimited = Data(#"{"error":{"code":403,"errors":[{"reason":"\#(reason)"}]}}"#.utf8)
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
}

@Suite struct LabelAndSearchTests {
    private let labelJSON = #"{"id":"Label_1","name":"Trips","type":"user"}"#

    @Test func labelPatchSendsOnlyTheGivenFieldsAndNullToRemoveAColor() async throws {
        let transport = StubTransport(Array(repeating: .init(status: 200, body: labelJSON), count: 3))
        let client = GmailClient(tokens: StubTokens(), transport: transport)
        let blue = try #require(LabelColor(backgroundColor: "#1C4587"))

        _ = try await client.patchLabel(id: "Label_1", name: "Trips")
        _ = try await client.patchLabel(id: "Label_1", color: .remove)
        _ = try await client.patchLabel(id: "Label_1", color: .set(blue))
        await #expect(throws: GmailError.invalidRequest("Empty label patch")) {
            try await client.patchLabel(id: "Label_1")
        }

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PATCH", "PATCH", "PATCH"])
        #expect(requests.first?.url?.path == "/gmail/v1/users/me/labels/Label_1")
        let bodies = try requests.map { try JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? NSDictionary }
        #expect(bodies[0] == ["name": "Trips"])
        #expect(bodies[1] == ["color": NSNull()])
        #expect(bodies[2] == ["color": ["backgroundColor": "#1c4587", "textColor": "#ffffff"]])
    }

    @Test func createLabelIsVisibleAndDeleteTreatsMissingAsDone() async throws {
        let transport = StubTransport([
            .init(status: 200, body: labelJSON),
            .init(status: 404, body: #"{"error":{"code":404}}"#),
            .init(status: 400, body: #"{"error":{"code":400}}"#),
        ])
        let client = GmailClient(tokens: StubTokens(), transport: transport)

        #expect(try await client.createLabel(name: "Trips", color: nil).id == "Label_1")
        try await client.deleteLabel(id: "Label_1")
        await #expect(throws: GmailError.http(status: 400, reason: nil)) { try await client.deleteLabel(id: "Label_2") }

        let requests = await transport.requests
        let created = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? NSDictionary
        #expect(created == ["name": "Trips", "labelListVisibility": "labelShow", "messageListVisibility": "show"])
        #expect(requests[1].httpMethod == "DELETE")
    }

    @Test func colorsOutsideGmailsListAreRejected() throws {
        #expect(LabelColor.allowed.count == 102)
        #expect(Set(LabelColor.allowed).count == 102)
        #expect(LabelColor.grid.count == 64)
        #expect(LabelColor(backgroundColor: "#123456") == nil)
        #expect(LabelColor(backgroundColor: "#000000", textColor: "#fb4c2e") == nil)
        #expect(LabelColor(backgroundColor: "#000000")?.textColor == "#ffffff")
        #expect(LabelColor(backgroundColor: "#ffffff")?.textColor == "#000000")
        let stored = Data(##"{"backgroundColor":"#123456","textColor":"#000000"}"##.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LabelColor.self, from: stored) }
    }

    @Test func threadSearchListsThenFetchesMetadataInOneBatch() async throws {
        let transport = StubTransport([
            .init(status: 200, body: #"{"threads":[{"id":"t1","snippet":"hi"}],"nextPageToken":"p2"}"#),
            batchResponse([(0, 200, #"{"id":"t1","messages":[{"id":"m1","threadId":"t1"}]}"#)]),
        ])
        let client = GmailClient(tokens: StubTokens(), transport: transport)

        let page = try await client.listThreads(query: "trail", pageToken: "p1")
        let threads = try await client.threads(ids: ["t1", "t1"], format: .metadata, metadataHeaders: ["Subject"])

        #expect(page.threads?.map(\.id) == ["t1"])
        #expect(page.nextPageToken == "p2")
        #expect(try threads["t1"]?.get().messages?.first?.id == "m1")
        let requests = await transport.requests
        #expect(requests[0].url?.path == "/gmail/v1/users/me/threads")
        #expect(requests[0].url?.query == "maxResults=25&q=trail&pageToken=p1")
        let batch = String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(batch.contains("GET /gmail/v1/users/me/threads/t1?format=metadata&metadataHeaders=Subject HTTP/1.1\r\n"))
    }

    @Test func defaultTransportHasNoURLCache() {
        #expect(GoogleSession.defaultTransport.configuration.urlCache == nil)
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
