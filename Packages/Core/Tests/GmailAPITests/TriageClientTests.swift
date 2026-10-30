import Foundation
import Testing
@testable import GmailAPI

@Suite struct TriageClientTests {
    @Test func rawMessageChecksIdentityAndDecodesOriginalBytes() async throws {
        let raw = Data("From: sender@example.com\r\nSubject: Original\r\n\r\nBody".utf8)
        let encoded = raw.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let transport = RecordingTransport([
            .init(status: 200, body: #"{"id":"m1","raw":"\#(encoded)"}"#),
            .init(status: 200, body: #"{"id":"another","raw":"YQ"}"#),
        ])
        let client = GmailClient(tokens: CountingTokens(), transport: transport)
        #expect(try await client.rawMessage(id: "m1") == raw)
        await #expect(throws: GmailError.decoding("Raw message")) { try await client.rawMessage(id: "m1") }
        await #expect(throws: GmailError.invalidRequest("Invalid mail identifier")) { try await client.rawMessage(id: "../settings") }
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.first?.url?.query == "format=raw")
    }

    @Test func permanentDeletionIsChunkedDeduplicatedAndContainsOnlyApprovedIDs() async throws {
        let transport = RecordingTransport([.init(status: 200, body: ""), .init(status: 200, body: "")])
        let client = GmailClient(tokens: CountingTokens(), transport: transport)
        let ids = (0..<1001).map { "m\($0)" }
        try await client.batchDeleteMessages(ids: ids + ["m0"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        let chunks = try requests.map { try $0.jsonBody()["ids"] as? [String] ?? [] }
        #expect(chunks.map(\.count) == [1000, 1])
        #expect(chunks.flatMap { $0 } == ids)
        #expect(requests.allSatisfy { $0.url?.path.hasSuffix("messages/batchDelete") == true && $0.httpMethod == "POST" })
    }

    @Test func visibilityPatchContainsNoUnrelatedLabelFields() async throws {
        let transport = RecordingTransport([.init(status: 200, body: #"{"id":"Label_work","name":"Work","labelListVisibility":"labelShowIfUnread"}"#)])
        let client = GmailClient(tokens: CountingTokens(), transport: transport)
        let label = try await client.patchLabelVisibility(id: "Label_work", visibility: .showIfUnread)
        #expect(label.labelListVisibility == "labelShowIfUnread")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        let body = try request.jsonBody()
        #expect(body.keys.sorted() == ["labelListVisibility"])
        #expect(body["labelListVisibility"] as? String == "labelShowIfUnread")
    }
}
