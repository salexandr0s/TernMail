import Foundation
import Testing
@testable import GmailAPI

@Suite struct GoogleTasksTests {
    @Test func paginationIncludesTasksCompletedInGoogleAndEncodesResourceIDs() async throws {
        let transport = RecordingTransport([
            .init(status: 200, body: #"{"items":[{"id":"list","title":"Work"}],"nextPageToken":"lists+2"}"#),
            .init(status: 200, body: #"{"items":[{"id":"list2","title":"Home"}]}"#),
            .init(status: 200, body: #"{"items":[{"id":"open","title":"Reply","status":"needsAction"}],"nextPageToken":"tasks+2"}"#),
            .init(status: 200, body: #"{"items":[{"id":"done","title":"Read","status":"completed","hidden":true},{"id":"gone","deleted":true}]}"#),
        ])
        let client = GoogleTasksClient(tokens: CountingTokens(), transport: transport)
        #expect(try await client.allTaskLists().map(\.id) == ["list", "list2"])
        let tasks = try await client.allTasks(listID: "work/a+b")
        #expect(tasks.map(\.id) == ["open", "done"])
        #expect(tasks.last?.isCompleted == true)
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[0].url?.host == "tasks.googleapis.com")
        #expect(requests[0].percentEncodedTarget == "/tasks/v1/users/@me/lists?maxResults=1000")
        #expect(requests[1].percentEncodedTarget == "/tasks/v1/users/@me/lists?maxResults=1000&pageToken=lists%2B2")
        #expect(requests[2].percentEncodedTarget?.contains("work%2Fa%2Bb") == true)
        #expect(requests[3].percentEncodedTarget?.contains("pageToken=tasks%2B2") == true)
        let query = try #require(requests[2].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        for flag in ["showCompleted", "showHidden", "showAssigned"] {
            #expect(query.contains(URLQueryItem(name: flag, value: "true")))
        }
        #expect(query.contains(URLQueryItem(name: "showDeleted", value: "false")))
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer token-0")
    }

    @Test func emptyPagesDecodeAndRepeatedTokensFailWithoutLooping() async throws {
        let empty = try JSONDecoder().decode(GoogleTaskPage.self, from: Data("{}".utf8))
        #expect(empty.items.isEmpty)
        let transport = RecordingTransport([
            .init(status: 200, body: #"{"nextPageToken":"again"}"#),
            .init(status: 200, body: #"{"nextPageToken":"again"}"#),
        ])
        let client = GoogleTasksClient(tokens: CountingTokens(), transport: transport)
        await #expect(throws: GmailError.decoding("Repeated task page token")) {
            _ = try await client.allTasks(listID: "list")
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func creationWritesCalendarDaysAndUpdatesPreserveUneditedFields() async throws {
        let transport = RecordingTransport([
            .init(status: 200, body: #"{"id":"task","title":"Plan","due":"2026-11-02T00:00:00.000Z","etag":"first"}"#),
            .init(status: 200, body: #"{"id":"task","title":"Plan","status":"needsAction","etag":"second"}"#),
            .init(status: 204, body: ""),
        ])
        let client = GoogleTasksClient(tokens: CountingTokens(), transport: transport)
        let created = try await client.insertTask(listID: "list", draft: .init(title: "Plan", notes: "Source email", due: "2026-11-02"))
        #expect(created.dueDay == "2026-11-02")
        _ = try await client.updateTask(listID: "list", taskID: created.id,
                                        update: .init(notes: "", due: .clear, isCompleted: false), etag: created.etag)
        try await client.deleteTask(listID: "list", taskID: created.id, etag: "second")
        let requests = await transport.requests
        let inserted = try requests[0].jsonBody()
        #expect(Set(inserted.keys) == ["title", "notes", "due"])
        #expect(inserted["due"] as? String == "2026-11-02T00:00:00.000Z")
        let changed = try requests[1].jsonBody()
        #expect(Set(changed.keys) == ["notes", "due", "status", "completed"])
        #expect(changed["due"] is NSNull)
        #expect(changed["completed"] is NSNull)
        #expect(changed["status"] as? String == "needsAction")
        #expect(requests[1].httpMethod == "PATCH")
        #expect(requests[1].value(forHTTPHeaderField: "If-Match") == "first")
        #expect(requests[2].httpMethod == "DELETE")
        #expect(requests[2].value(forHTTPHeaderField: "If-Match") == "second")
        #expect(requests[2].httpBody == nil)
    }

    @Test func completionDoesNotResendNotesOrDates() throws {
        let data = try JSONEncoder().encode(GoogleTaskUpdate(isCompleted: true))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["status": "completed"])
    }

    @Test func calendarDayDoesNotShiftAcrossTimeZonesAndInvalidDaysFail() throws {
        for name in ["America/Los_Angeles", "Pacific/Auckland", "Europe/Vienna"] {
            let zone = try #require(TimeZone(identifier: name))
            let day = try #require(GoogleTaskDateCoding.date("2026-11-02T00:00:00.000Z", timeZone: zone))
            #expect(GoogleTaskDateCoding.string(day, timeZone: zone) == "2026-11-02")
        }
        #expect(GoogleTaskDateCoding.date("2026-02-30") == nil)
        #expect(GoogleTaskDateCoding.date("2026-11-02-junk") == nil)
        #expect(throws: (any Error).self) { try JSONEncoder().encode(GoogleTaskDraft(title: "Plan", due: "2026-02-30")) }
        #expect(throws: (any Error).self) { try JSONEncoder().encode(GoogleTaskDraft(title: " ")) }
        #expect(throws: (any Error).self) { try JSONEncoder().encode(GoogleTaskDraft(title: String(repeating: "x", count: 1025))) }
        #expect(throws: (any Error).self) { try JSONEncoder().encode(GoogleTaskDraft(title: "Plan", notes: String(repeating: "x", count: 8193))) }
    }

    @Test func anAmbiguousCreationFailureIsNeverRetried() async throws {
        let transport = RecordingTransport([
            .init(status: 503, body: #"{"error":{"code":503}}"#),
            .init(status: 200, body: #"{"id":"would-duplicate","title":"Plan"}"#),
        ])
        let client = GoogleTasksClient(tokens: CountingTokens(), transport: transport)
        await #expect(throws: GmailError.server(status: 503)) {
            _ = try await client.insertTask(listID: "list", draft: .init(title: "Plan"))
        }
        #expect(await transport.requests.count == 1)
        let offline = TasksFailedTransport()
        let disconnected = GoogleTasksClient(tokens: CountingTokens(), transport: offline)
        await #expect(throws: GmailError.transport(.networkConnectionLost)) {
            _ = try await disconnected.insertTask(listID: "list", draft: .init(title: "Plan"))
        }
        #expect(await offline.calls == 1)
    }

    @Test func aConflictIsReturnedWithoutOverwritingTheNewerTask() async throws {
        let transport = RecordingTransport([.init(status: 412, body: #"{"error":{"code":412}}"#)])
        let client = GoogleTasksClient(tokens: CountingTokens(), transport: transport)
        await #expect(throws: GmailError.http(status: 412, reason: nil)) {
            _ = try await client.updateTask(listID: "list", taskID: "task", update: .init(title: "Changed"), etag: "old")
        }
        #expect(await transport.requests.count == 1)
    }
}

private actor TasksFailedTransport: HTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        throw URLError(.networkConnectionLost)
    }
}
