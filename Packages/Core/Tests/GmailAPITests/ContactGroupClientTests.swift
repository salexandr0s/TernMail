import Foundation
import Testing
@testable import GmailAPI

@Suite struct ContactGroupClientTests {
    @Test func cataloguePagesKeepOnlyUserGroupsAndGroupFetchRequestsMembers() async throws {
        let transport = RecordingTransport([
            .init(status: 200, body: #"{"contactGroups":[{"resourceName":"contactGroups/system","name":"All","groupType":"SYSTEM_CONTACT_GROUP"},{"resourceName":"contactGroups/team","name":"Team","groupType":"USER_CONTACT_GROUP","memberCount":1}],"nextPageToken":"next"}"#),
            .init(status: 200, body: #"{"contactGroups":[{"resourceName":"contactGroups/other","name":"Other","groupType":"USER_CONTACT_GROUP","memberCount":0}]}"#),
            .init(status: 200, body: #"{"resourceName":"contactGroups/team","name":"Team","groupType":"USER_CONTACT_GROUP","memberCount":1,"memberResourceNames":["people/one"]}"#),
        ])
        let client = PeopleClient(tokens: CountingTokens(), transport: transport)
        let catalog = try await client.contactGroups()
        #expect(catalog.isComplete)
        #expect(catalog.groups.map(\.resourceName) == ["contactGroups/team", "contactGroups/other"])
        #expect(try await client.contactGroup(resourceName: "contactGroups/team").memberResourceNames == ["people/one"])
        let requests = await transport.requests
        #expect(URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "maxMembers", value: "1000")) == true)
        #expect(requests[1].url?.query?.contains("pageToken=next") == true)
        await #expect(throws: GmailError.self) { try await client.contactGroup(resourceName: "contactGroups/../people/me") }
        #expect(await transport.requests.count == 3)
    }

    @Test func memberBatchesNeverExceedTwoHundredAndKeepMissingIdentities() async throws {
        let ids = (0..<201).map { "people/c\($0)" }.sorted()
        let responses = try stride(from: 0, to: ids.count, by: 200).map { start -> RecordingTransport.Response in
            let chunk = Array(ids[start..<min(start + 200, ids.count)])
            let items: [[String: Any]] = chunk.map { id in
                if id == "people/c9" { return ["requestedResourceName": id, "status": ["code": 5]] }
                return ["requestedResourceName": id, "person": ["resourceName": id, "emailAddresses": [["value": "member@example.test"]]]]
            }
            return .init(status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: ["responses": items]), as: UTF8.self))
        }
        let transport = RecordingTransport(responses)
        let client = PeopleClient(tokens: CountingTokens(), transport: transport)
        let result = try await client.contactGroupPeople(resourceNames: ids)
        #expect(result.peopleByResourceName.count == 200)
        #expect(result.missingResourceNames == ["people/c9"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "resourceNames" }.count } == [200, 1])
    }

    @Test func photosPreferPrimaryNondefaultAndBothSourcesRequestThePhotoMask() throws {
        let person = try JSONDecoder().decode(Person.self, from: Data(#"{"resourceName":"people/a","photos":[{"url":"https://lh3.googleusercontent.com/default","default":true,"metadata":{"primary":true}},{"url":"https://lh3.googleusercontent.com/person","default":false}]}"#.utf8))
        #expect(person.photoURL?.lastPathComponent == "person")
        #expect(PeopleClient.fields.split(separator: ",").contains("photos"))
    }
}
