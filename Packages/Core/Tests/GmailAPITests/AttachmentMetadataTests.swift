import Foundation
import Testing
@testable import GmailAPI

@Suite struct AttachmentMetadataTests {
    @Test func metadataRequestsExcludeFileBytesAtEveryRequestedDepth() async throws {
        let body = "--resp\r\nContent-Type: application/http\r\nContent-ID: <response-item-0>\r\n\r\n"
            + "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
            + #"{"id":"old","threadId":"thread","payload":{"filename":"invoice.pdf","body":{"size":4,"attachmentId":"file"}}}"#
            + "\r\n--resp--\r\n"
        let transport = RecordingTransport([.init(status: 200,
            headers: ["Content-Type": "multipart/mixed; boundary=resp"], body: body)])
        let client = GmailClient(tokens: CountingTokens(), transport: transport)
        let result = try await client.attachmentMetadata(ids: ["old"])
        #expect(try result["old"]?.get().payload?.body?.attachmentId == "file")
        let request = try #require(await transport.requests.first)
        let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self).removingPercentEncoding ?? ""
        #expect(raw.contains("format=full"))
        #expect(raw.contains("fields=id,threadId,historyId,labelIds,internalDate,payload("))
        #expect(!raw.contains("data"))
        #expect(GmailClient.attachmentMetadataFields.components(separatedBy: "body(attachmentId,size)").count - 1
            == GmailClient.attachmentMetadataDepth + 1)
        #expect(!GmailClient.attachmentMetadataFields.contains("*"))
    }

    @Test func indexHistoryUsesSmallPagesAndPreservesCursorAndToken() async throws {
        let transport = RecordingTransport([.init(status: 200, body: #"{"historyId":"200"}"#)])
        let client = GmailClient(tokens: CountingTokens(), transport: transport)
        _ = try await client.attachmentHistory(startHistoryID: "100", pageToken: "page-2")
        let request = try #require(await transport.requests.first)
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "maxResults", value: "25")))
        #expect(query.contains(URLQueryItem(name: "startHistoryId", value: "100")))
        #expect(query.contains(URLQueryItem(name: "pageToken", value: "page-2")))
    }
}
