import Foundation
import Testing
@testable import GmailAPI

@Suite struct PeopleClientTests {
    private func client(_ responses: [RecordingTransport.Response]) -> (PeopleClient, RecordingTransport, CountingTokens) {
        let transport = RecordingTransport(responses)
        let tokens = CountingTokens()
        return (PeopleClient(tokens: tokens, transport: transport), transport, tokens)
    }

    private func query(_ request: URLRequest) -> [String: [String]] {
        guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(grouping: items, by: \.name).mapValues { $0.compactMap(\.value) }
    }

    // MARK: Contact lists

    @Test func aFullSyncKeepsItsParametersAcrossPagesAndEndsWithTheLastToken() async throws {
        let first = #"{"connections": [{"resourceName": "people/c1", "emailAddresses": [{"value": "ann@example.com"}]}], "nextPageToken": "p2"}"#
        let last = #"{"connections": [{"resourceName": "people/c2"}], "nextSyncToken": "s1"}"#
        let (people, transport, _) = client([.init(status: 200, body: first), .init(status: 200, body: last)])

        let sync = try await people.sync(.connections)
        #expect(sync.people.map(\.resourceName) == ["people/c1", "people/c2"])
        #expect(sync.syncToken == "s1")

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/v1/people/me/connections" })
        var firstQuery = query(requests[0])
        var secondQuery = query(requests[1])
        #expect(firstQuery["personFields"] == ["names,emailAddresses,metadata"])
        #expect(firstQuery["pageSize"] == ["1000"])
        #expect(firstQuery["requestSyncToken"] == ["true"])
        #expect(firstQuery["syncToken"] == nil && firstQuery["pageToken"] == nil)
        #expect(secondQuery.removeValue(forKey: "pageToken") == ["p2"])
        firstQuery.removeValue(forKey: "pageToken")
        #expect(firstQuery == secondQuery)
    }

    @Test func anIncrementalSyncSendsItsTokenOnEveryPageAndMarksDeletedPeople() async throws {
        let first = #"{"otherContacts": [{"resourceName": "otherContacts/c1", "metadata": {"deleted": true}}], "nextPageToken": "p2"}"#
        let last = #"{"otherContacts": [{"resourceName": "otherContacts/c2", "names": [{"displayName": "Bo"}]}], "nextSyncToken": "s2"}"#
        let (people, transport, _) = client([.init(status: 200, body: first), .init(status: 200, body: last)])

        let sync = try await people.sync(.otherContacts, syncToken: "s1")
        #expect(sync.people.map(\.isDeleted) == [true, false])
        #expect(sync.syncToken == "s2")

        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url?.path == "/v1/otherContacts" })
        for request in requests {
            let items = query(request)
            #expect(items["syncToken"] == ["s1"])
            #expect(items["requestSyncToken"] == ["true"])
            #expect(items["readMask"] == ["names,emailAddresses,metadata"])
        }
    }

    @Test(arguments: [400, 410])
    func aRejectedSyncTokenIsReportedAndTheSameStatusWithoutOneThrows(status: Int) async throws {
        let body = #"{"error": {"code": \#(status)}}"#
        let (people, _, _) = client([.init(status: status, body: body), .init(status: status, body: body)])
        await #expect(throws: PeopleError.syncTokenRejected(status: status)) {
            try await people.page(.connections, syncToken: "old")
        }
        await #expect(throws: GmailError.http(status: status, reason: nil)) {
            try await people.page(.connections)
        }
    }

    @Test func requestsGoToThePeopleHostAndRefreshTheTokenOnceAfterA401() async throws {
        let (people, transport, tokens) = client([
            .init(status: 401, body: "{}"),
            .init(status: 200, body: #"{"connections": []}"#),
        ])
        let page = try await people.page(.connections)
        #expect(page.people.isEmpty && page.nextSyncToken == nil)
        #expect(await tokens.refreshes == 1)

        let requests = await transport.requests
        #expect(requests.map { $0.url?.host } == ["people.googleapis.com", "people.googleapis.com"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-0", "Bearer token-1"])
    }

    // MARK: Directory

    @Test func directorySearchSendsBothSourcesAndEncodesPlus() async throws {
        let body = #"{"people": [{"resourceName": "people/d1", "emailAddresses": [{"value": "a+b@example.com"}]}]}"#
        let (people, transport, _) = client([.init(status: 200, body: body)])
        let page = try await people.searchDirectory("a+b", pageSize: 900)
        #expect(page.people.first?.addresses == ["a+b@example.com"])

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/v1/people:searchDirectoryPeople")
        #expect(request.percentEncodedTarget?.contains("query=a%2Bb") == true)
        let items = query(request)
        #expect(items["sources"] == ["DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE", "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"])
        #expect(items["pageSize"] == ["500"])
    }

    @Test func aRefusedDirectoryReadsAsUnavailableButAMissingScopeDoesNot() async throws {
        let refused = #"{"error": {"code": 403, "status": "PERMISSION_DENIED"}}"#
        let scope = #"{"error": {"code": 403, "errors": [{"reason": "insufficientPermissions"}]}}"#
        let (people, transport, _) = client([.init(status: 403, body: refused), .init(status: 403, body: scope)])
        await #expect(throws: PeopleError.directoryUnavailable) { try await people.searchDirectory("ann") }
        await #expect(throws: GmailError.http(status: 403, reason: "insufficientPermissions")) {
            try await people.searchDirectory("ann")
        }

        // Blank text never reaches the API.
        #expect(try await people.searchDirectory("  ").people.isEmpty)
        #expect(await transport.requests.count == 2)
    }

    // MARK: Person

    @Test func thePrimaryNameWinsAndPeopleWithoutAddressesHaveNone() throws {
        let json = #"""
        [{"resourceName": "people/c1",
          "names": [{"displayName": "Old Name"}, {"givenName": "Ann", "familyName": "Lee", "metadata": {"primary": true}}],
          "emailAddresses": [{"value": "ann@example.com"}, {"value": " Ann@Example.com ", "metadata": {"primary": true}}, {"value": " "}]},
         {"resourceName": "people/c2", "names": [{"displayName": "No Mail"}]}]
        """#
        let decoded = try JSONDecoder().decode([Person].self, from: Data(json.utf8))
        #expect(decoded[0].displayName == "Ann Lee")
        #expect(decoded[0].addresses == ["Ann@Example.com"])
        #expect(decoded[1].displayName == "No Mail")
        #expect(decoded[1].addresses.isEmpty)
    }
}
