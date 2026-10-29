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
