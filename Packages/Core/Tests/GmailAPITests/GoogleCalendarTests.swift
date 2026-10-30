import Foundation
import Testing
@testable import GmailAPI

@Suite struct GoogleCalendarTests {
    @Test func resourceIdentityAndQueriesAreEncodedAsComponents() async throws {
        let transport = RecordingTransport([.init(status: 200, body: #"{"items":[],"nextSyncToken":"next"}"#)])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        let result = try await client.events(calendarID: "shared/a+b@example.invalid", query: .init(iCalUID: "meeting+a/b", query: "a+b"))
        #expect(result.items.isEmpty)
        #expect(result.nextSyncToken == "next")
        let request = try #require(await transport.requests.first)
        #expect(request.percentEncodedTarget?.contains("shared%2Fa%2Bb%40example.invalid") == true)
        #expect(request.percentEncodedTarget?.contains("q=a%2Bb") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-0")
    }

    @Test func updatesSendOnlyChangedFieldsWithConcurrencyAndNotificationOptions() async throws {
        let transport = RecordingTransport([.init(status: 200, body: #"{"id":"event","etag":"new"}"#)])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        let original = try JSONDecoder().decode(GoogleCalendarEvent.self, from: Data(#"{"id":"event","etag":"old","summary":"Before","description":"Private note","conferenceData":{"conferenceId":"preserve"},"futureGoogleField":{"keep":true}}"#.utf8))
        var edited = original
        edited.summary = "After"
        edited.description = nil
        let patch = edited.changedFields(from: original)
        #expect(patch == ["summary": .string("After"), "description": .null])
        _ = try await client.patchEvent(calendarID: "primary", eventID: "event", fields: patch, etag: "old", sendUpdates: "all")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "If-Match") == "old")
        #expect(request.percentEncodedTarget?.contains("sendUpdates=all") == true)
        #expect(request.percentEncodedTarget?.contains("conferenceDataVersion=1") == true)
        let body = try request.jsonBody()
        #expect(body.count == 2)
        #expect(body["description"] is NSNull)
        #expect(edited.rawValue["futureGoogleField"] == original.rawValue["futureGoogleField"])
        #expect(edited.conferenceData?.conferenceId == "preserve")
    }

    @Test func syncExpiryIsDistinctFromMissingEventsAndInvalidFiltersNeverReachGoogle() async throws {
        let transport = RecordingTransport([
            .init(status: 410, body: #"{"error":{"code":410,"message":"gone"}}"#),
            .init(status: 404, body: #"{"error":{"code":404,"message":"gone"}}"#),
        ])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        await #expect(throws: CalendarAPIError.syncTokenExpired) {
            try await client.events(calendarID: "primary", query: .init(syncToken: "expired"))
        }
        await #expect(throws: GmailError.self) { try await client.event(calendarID: "primary", eventID: "missing") }
        await #expect(throws: GmailError.self) {
            try await client.events(calendarID: "primary", query: .init(syncToken: "token", timeMin: .now))
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func partialAvailabilityDoesNotDisappearDuringDecoding() async throws {
        let transport = RecordingTransport([.init(status: 200, body: #"{"timeMin":"2026-10-30T00:00:00Z","timeMax":"2026-10-31T00:00:00Z","calendars":{"work":{"busy":[{"start":"2026-10-30T10:00:00+01:00","end":"2026-10-30T11:00:00+01:00"}]},"private":{"errors":[{"domain":"global","reason":"notFound"}]}}}"#)])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        let start = try #require(CalendarDateCoding.date("2026-10-30T00:00:00Z"))
        let result = try await client.freeBusy(calendarIDs: ["work", "private"], start: start, end: start.addingTimeInterval(86400), timeZone: "Europe/Vienna")
        #expect(result.calendars["work"]?.busy.first?.startDate == CalendarDateCoding.date("2026-10-30T09:00:00Z"))
        #expect(result.calendars["private"]?.errors?.first?.reason == "notFound")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(try request.jsonBody()["timeZone"] as? String == "Europe/Vienna")
    }

    @Test func allDayDatesKeepTheirCalendarDayAcrossDaylightSaving() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let start = CalendarDateTime(date: "2026-03-29")
        let end = CalendarDateTime(date: "2026-03-30")
        let startDate = try #require(start.resolvedDate(fallbackTimeZone: zone))
        let endDate = try #require(end.resolvedDate(fallbackTimeZone: zone))
        #expect(endDate.timeIntervalSince(startDate) == 23 * 3600)
        #expect(CalendarDateTime(date: startDate, timeZone: zone, allDay: true).date == "2026-03-29")
        #expect(CalendarDateTime(date: "2026-02-31").resolvedDate(fallbackTimeZone: zone) == nil)
        #expect(CalendarDateTime(date: "2026-2-3").resolvedDate(fallbackTimeZone: zone) == nil)
        #expect(CalendarDateCoding.date("2026-10-30T10:00:00.123Z") != nil)
        #expect(CalendarDateTime(dateTime: "2026-10-30T10:00:00", timeZone: "Europe/Vienna").resolvedDate() == CalendarDateCoding.date("2026-10-30T09:00:00Z"))
        #expect(CalendarDateTime(date: "2026-10-30", dateTime: "2026-10-30T10:00:00Z").resolvedDate() == nil)
    }

    @Test func sparseCancelledEventsAndUnknownFieldsRoundTrip() throws {
        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: Data(#"{"id":"cancelled-instance","status":"cancelled","recurringEventId":"series","originalStartTime":{"date":"2026-12-01"},"newField":[true,{"hello":"world"}]}"#.utf8))
        #expect(event.isCancelled)
        #expect(event.start == nil)
        #expect(event.originalStartTime?.date == "2026-12-01")
        #expect(try JSONDecoder().decode(GoogleCalendarEvent.self, from: JSONEncoder().encode(event)) == event)
        #expect(try JSONDecoder().decode(CalendarEventPage.self, from: Data(#"{"nextSyncToken":"empty"}"#.utf8)).items.isEmpty)
    }

    @Test func importingPreservesInvitationIdentityAndDoesNotSendInvitations() async throws {
        let transport = RecordingTransport([.init(status: 200, body: #"{"id":"server-id","iCalUID":"invitation-uid"}"#)])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        var event = GoogleCalendarEvent(id: "local-id", summary: "Imported", start: .init(date: "2026-10-30"), end: .init(date: "2026-10-31"))
        event.iCalUID = "invitation-uid"
        event.organizer = CalendarPerson(email: "organizer@example.invalid")
        _ = try await client.importEvent(calendarID: "primary", event: event)
        let request = try #require(await transport.requests.first)
        let body = try request.jsonBody()
        #expect(request.url?.path.hasSuffix("/events/import") == true)
        #expect(request.percentEncodedTarget?.contains("sendUpdates") == false)
        #expect(body["id"] == nil)
        #expect(body["iCalUID"] as? String == "invitation-uid")
        #expect((body["organizer"] as? [String: String])?["email"] == "organizer@example.invalid")
    }

    @Test func calendarAndSharingRequestsRetainIdentityAndEtag() async throws {
        let transport = RecordingTransport([
            .init(status: 200, body: ##"{"id":"shared","backgroundColor":"#ff0000"}"##),
            .init(status: 200, body: #"{"id":"user:guest@example.invalid","role":"reader","scope":{"type":"user","value":"guest@example.invalid"}}"#),
            .init(status: 204, body: ""),
        ])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        _ = try await client.patchCalendarList(calendarID: "shared", fields: ["backgroundColor": .string("#ff0000")], etag: "calendar-version")
        let rule = try await client.insertACL(calendarID: "shared", rule: .init(role: "reader", scopeValue: "guest@example.invalid"))
        try await client.deleteACL(calendarID: "shared", ruleID: rule.id, etag: "rule-version")
        let requests = await transport.requests
        #expect(requests[0].value(forHTTPHeaderField: "If-Match") == "calendar-version")
        #expect(requests[0].percentEncodedTarget?.contains("colorRgbFormat=true") == true)
        #expect(requests[1].percentEncodedTarget?.contains("sendNotifications=true") == true)
        #expect(requests[2].httpMethod == "DELETE")
        #expect(requests[2].value(forHTTPHeaderField: "If-Match") == "rule-version")
        #expect(requests[2].percentEncodedTarget?.contains("user%3Aguest%40example.invalid") == true)
    }

    @Test func calendarScopesDoNotImplySharingAndMissingFreeBusyKeepsFeatureOff() throws {
        let eventOnly = GoogleScopes.base + [GoogleScopes.calendarEvents, GoogleScopes.calendarList]
        let grant = try FeatureGrant(subject: "account", granted: eventOnly, accountID: "account", features: [.calendar])
        #expect(grant.features.isEmpty)
        #expect(grant.missingScopes == [GoogleScopes.calendarFreeBusy])
        let requested = GoogleScopes.request(features: [.calendar], isWorkspace: false)
        #expect(!requested.contains(GoogleScopes.calendarSharing))
        #expect(!requested.contains(GoogleScopes.calendarManagement))
        #expect(GoogleScopes.isCovered(.calendar, by: [GoogleScopes.fullCalendar]))
        #expect(GoogleScopes.isCovered(.calendarManagement, by: [GoogleScopes.fullCalendar]))
        #expect(GoogleScopes.isCovered(.calendarSharing, by: [GoogleScopes.fullCalendar]))
        #expect(!GoogleScopes.isCovered(.calendar, by: ["https://www.googleapis.com/auth/calendar.readonly"]))
    }

    @Test func malformedAvailabilityAndMissingResourceIDsFailClosed() async throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CalendarFreeBusyResponse.self, from: Data(#"{"calendars":{"work":{}}}"#.utf8))
        }
        let transport = RecordingTransport([.init(status: 200, body: #"{"items":[{"summary":"No identity"}]}"#)])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        await #expect(throws: GmailError.self) { try await client.calendarList() }
    }

    @Test func calendarResourceHasItsOwnEndpointAndVersion() async throws {
        let transport = RecordingTransport([.init(status: 200, body: #"{"id":"calendar-id","summary":"Team","etag":"calendar-resource-version"}"#)])
        let client = GoogleCalendarClient(tokens: CountingTokens(), transport: transport)
        let calendar = try await client.calendar(calendarID: "calendar-id")
        #expect(calendar.etag == "calendar-resource-version")
        #expect(await transport.requests.first?.url?.path == "/calendar/v3/calendars/calendar-id")
    }
}
