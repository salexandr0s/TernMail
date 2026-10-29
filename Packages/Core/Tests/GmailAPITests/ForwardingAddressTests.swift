import Foundation
import Testing
@testable import GmailAPI

@Suite struct ForwardingAddressTests {
    @Test func forwardingAddressesDecodeEveryVerificationStatus() async throws {
        let body = #"""
        {"forwardingAddresses": [
          {"forwardingEmail": "archive@example.com", "verificationStatus": "accepted"},
          {"forwardingEmail": "new@example.com", "verificationStatus": "pending"},
          {"forwardingEmail": "old@example.com"},
          {"forwardingEmail": "later@example.com", "verificationStatus": "someLaterValue"}
        ]}
        """#
        let transport = RecordingTransport([.init(status: 200, body: body)])
        let addresses = try await GmailClient(tokens: CountingTokens(), transport: transport).forwardingAddresses()

        #expect(addresses.map(\.forwardingEmail) == ["archive@example.com", "new@example.com", "old@example.com", "later@example.com"])
        #expect(addresses.map(\.verificationStatus) == [.accepted, .pending, .unspecified, .unspecified])
        #expect(addresses.map(\.isAccepted) == [true, false, false, false])

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/gmail/v1/users/me/settings/forwardingAddresses")
    }

    @Test func anAccountWithoutForwardingAddressesListsNone() async throws {
        // Gmail leaves out `forwardingAddresses` when there are none.
        let transport = RecordingTransport([.init(status: 200, body: "{}")])
        #expect(try await GmailClient(tokens: CountingTokens(), transport: transport).forwardingAddresses().isEmpty)
    }
}
