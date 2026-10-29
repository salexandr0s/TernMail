import Foundation
import Testing
@testable import GmailAPI

@Suite struct GmailSettingsTests {
    private func client(_ responses: [RecordingTransport.Response]) -> (GmailClient, RecordingTransport) {
        let transport = RecordingTransport(responses)
        return (GmailClient(tokens: CountingTokens(), transport: transport), transport)
    }

    // MARK: Filters

    @Test func anAccountWithoutFiltersListsNone() async throws {
        // Gmail leaves out `filter` when there are none.
        let (gmail, _) = client([.init(status: 200, body: "{}")])
        #expect(try await gmail.filters().isEmpty)
    }

    @Test func filtersDecodeCriteriaActionsAndUnknownSizeComparisons() async throws {
        let body = #"""
        {"filter": [
          {"id": "f1", "criteria": {"from": "news@example.com", "size": 1000, "sizeComparison": "someLaterValue"},
           "action": {"addLabelIds": ["Label_1"], "removeLabelIds": ["INBOX"], "forward": "copy@example.com"}},
          {"id": "f2", "criteria": {"hasAttachment": true}}
        ]}
        """#
        let (gmail, transport) = client([.init(status: 200, body: body)])
        let filters = try await gmail.filters()
        #expect(filters.count == 2)
        #expect(filters[0].criteria.sizeComparison == .unspecified)
        #expect(filters[0].action.forward == "copy@example.com")
        #expect(filters[1].action == GmailFilter.Action())
        #expect(await transport.requests.first?.url?.path == "/gmail/v1/users/me/settings/filters")
    }

    @Test func createdFiltersSendOnlyTheSetFieldsAndNeedAnID() async throws {
        let created = #"{"id": "new1", "criteria": {"subject": "Invoice"}, "action": {"addLabelIds": ["Label_2"]}}"#
        let (gmail, transport) = client([.init(status: 200, body: created), .init(status: 200, body: "{}")])
        let criteria = GmailFilter.Criteria(subject: "Invoice", size: 5_000_000, sizeComparison: .larger)
        let filter = try await gmail.createFilter(criteria: criteria, action: .init(addLabelIds: ["Label_2"]))
        #expect(filter.id == "new1")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        let json = try request.jsonBody()
        #expect(json["id"] == nil)
        let sentCriteria = try #require(json["criteria"] as? [String: Any])
        #expect(Set(sentCriteria.keys) == ["subject", "size", "sizeComparison"])
        #expect(sentCriteria["sizeComparison"] as? String == "larger")

        // A response without an ID can't be recorded or deleted later.
        await #expect(throws: GmailError.decoding("GmailFilter.id")) {
            try await gmail.createFilter(criteria: criteria, action: .init())
        }
    }

    @Test func deletingAFilterThatIsAlreadyGoneSucceeds() async throws {
        let (gmail, transport) = client([.init(status: 404, body: #"{"error":{"code":404}}"#)])
        try await gmail.deleteFilter(id: "f1")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.percentEncodedTarget == "/gmail/v1/users/me/settings/filters/f1")
    }

    @Test func sameRulesIgnoreIDsSpacingLabelOrderAndUnsetValues() {
        let stored = GmailFilter(
            id: "f1",
            criteria: .init(from: "boss@example.com", hasAttachment: false, sizeComparison: .unspecified),
            action: .init(addLabelIds: ["B", "A"], removeLabelIds: [])
        )
        let edited = GmailFilter(criteria: .init(from: " boss@example.com "), action: .init(addLabelIds: ["A", "B"]))
        #expect(stored.hasSameRules(as: edited))

        let different = GmailFilter(criteria: .init(from: "boss@example.com"), action: .init(addLabelIds: ["A"]))
        #expect(!stored.hasSameRules(as: different))
    }

    // MARK: Vacation

    @Test func vacationTimesRoundTripAsMillisecondStrings() async throws {
        let body = #"""
        {"enableAutoReply": true, "responseSubject": "Away", "restrictToContacts": true,
         "startTime": "1767225600000", "endTime": "1767830400000"}
        """#
        let (gmail, transport) = client([.init(status: 200, body: body), .init(status: 200, body: body)])
        var settings = try await gmail.vacation()
        #expect(settings.startTime == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(settings.restrictToDomain == false)

        settings.responseBodyPlainText = "Back next week."
        _ = try await gmail.updateVacation(settings)
        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PUT")
        let json = try request.jsonBody()
        #expect(json["startTime"] as? String == "1767225600000")
        #expect(json["endTime"] as? String == "1767830400000")
        // Every field goes out, unset ones as null.
        #expect(json.count == 8)
        #expect(json["responseBodyHtml"] is NSNull)
    }

    @Test func invalidVacationUpdatesFailBeforeAnyRequest() async throws {
        let (gmail, transport) = client([])
        let start = Date(timeIntervalSince1970: 1_767_830_400)
        let backwards = VacationSettings(responseSubject: "Away", startTime: start, endTime: start.addingTimeInterval(-86_400))
        await #expect(throws: GmailError.self) { try await gmail.updateVacation(backwards) }

        let empty = VacationSettings(enableAutoReply: true, responseSubject: "  ", responseBodyPlainText: "")
        await #expect(throws: GmailError.self) { try await gmail.updateVacation(empty) }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: Send-as

    @Test func identitiesDecodeFlagsAndVerification() async throws {
        let body = #"""
        {"sendAs": [
          {"sendAsEmail": "me@example.com", "displayName": "Me", "signature": "<b>Me</b>", "isPrimary": true, "isDefault": true},
          {"sendAsEmail": "alias@example.com", "treatAsAlias": true, "verificationStatus": "pending"},
          {"sendAsEmail": "team@example.com", "replyToAddress": "help@example.com", "verificationStatus": "accepted"}
        ]}
        """#
        let (gmail, _) = client([.init(status: 200, body: body)])
        let identities = try await gmail.sendAsIdentities()
        #expect(identities.map(\.canSend) == [true, false, true])
        #expect(identities[0].verificationStatus == .unspecified)
        #expect(identities[1].treatAsAlias && !identities[1].isDefault)
        #expect(identities[2].replyToAddress == "help@example.com")
    }

    @Test func signatureUpdatesPatchOnlyTheSignatureAtAnAddressEncodedOnce() async throws {
        let body = #"{"sendAsEmail": "a+b@example.com", "signature": "<i>Thanks</i>"}"#
        let (gmail, transport) = client([.init(status: 200, body: body)])
        let identity = try await gmail.updateSignature(sendAsEmail: "a+b@example.com", signature: "<i>Thanks</i>")
        #expect(identity.signature == "<i>Thanks</i>")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.percentEncodedTarget == "/gmail/v1/users/me/settings/sendAs/a%2Bb%40example.com")
        #expect(try request.jsonBody().keys.sorted() == ["signature"])
    }

    @Test func aMissingScopeIsRecognizable() async throws {
        let refusal = #"{"error": {"code": 403, "errors": [{"reason": "insufficientPermissions"}]}}"#
        let (gmail, _) = client([.init(status: 403, body: refusal)])
        do {
            _ = try await gmail.createFilter(criteria: .init(from: "x@example.com"), action: .init(removeLabelIds: ["INBOX"]))
            Issue.record("Expected a 403")
        } catch let error as GmailError {
            #expect(error.isMissingScope)
        }
        #expect(!GmailError.http(status: 403, reason: "forbidden").isMissingScope)
    }
}
