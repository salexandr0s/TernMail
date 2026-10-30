import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct CalendarBodyTests {
    @Test func openingAThreadDownloadsAndStoresTheFirstUsableInvitation() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try thread([message("m1", parts: [
            #"{"mimeType":"text/plain","body":{"attachmentId":"body"}}"#,
            calendarPart("oversized", size: ICalendar.maxSize + 1),
            calendarPart("malformed"), calendarPart("invite"), calendarPart("unused"),
            #"{"mimeType":"text/plain","filename":"notes.txt","body":{"attachmentId":"file","size":5}}"#,
        ])]))
        await gmail.setAttachment("body", data: Data("Meeting details".utf8))
        await gmail.setAttachment("malformed", data: Data("Not a calendar".utf8))
        await gmail.setAttachment("invite", data: calendar())

        try await engine.openThread("t1")

        #expect(await gmail.attachmentRequests == ["body", "malformed", "invite"])
        #expect(try await cache.read { tx in try tx.body(messageID: "m1", accountID: account)?.plainText } == "Meeting details")
        let stored = try #require(try await cache.read { tx in try tx.messageCalendar(messageID: "m1", accountID: account) })
        #expect(stored.invitation == (try Invitation(data: calendar())))
    }

    @Test func failedFetchPreservesExistingDataAndSuccessfulRetryClearsAStaleInvitation() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t1", [SystemLabel.inbox])])
        let original = try Invitation(data: calendar())
        try await cache.write { tx in
            try tx.saveBodies([
                MessageBodyRecord(accountID: account, messageID: "m1", html: nil, plainText: "Original", fetchedAt: baseDate),
            ], calendars: [MessageCalendarRecord(accountID: account, messageID: "m1", invitation: original)])
        }
        // m2 lacks a body, so opening fetches the full thread, including m1.
        await gmail.setThread(try thread([
            message("m1", parts: [plainPart("Updated")]),
            message("m2", parts: [plainPart("New message"), calendarPart("invite")]),
        ]))

        await #expect(throws: GmailError.notFound) { try await engine.openThread("t1") }
        #expect(try await cache.read { tx in try tx.body(messageID: "m1", accountID: account)?.plainText } == "Original")
        #expect(try await cache.read { tx in try tx.messageCalendar(messageID: "m1", accountID: account)?.invitation } == original)
        #expect(try await cache.read { tx in try tx.body(messageID: "m2", accountID: account) } == nil)

        await gmail.setAttachment("invite", data: calendar())
        try await engine.openThread("t1")
        #expect(try await cache.read { tx in try tx.body(messageID: "m1", accountID: account)?.plainText } == "Updated")
        #expect(try await cache.read { tx in try tx.messageCalendar(messageID: "m1", accountID: account) } == nil)
        #expect(try await cache.read { tx in try tx.messageCalendar(messageID: "m2", accountID: account)?.invitation } == original)
    }

    @Test func cancelledFetchDoesNotStoreTheBodyOrInvitation() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try thread([message("m1", parts: [plainPart("Meeting"), inlineCalendar()])]))
        await gmail.holdNextThread()
        let loading = Task { try await engine.openThread("t1") }
        while await !gmail.isHoldingThread { await Task.yield() }
        loading.cancel()
        await gmail.releaseThread()

        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(try await cache.read { tx in try tx.body(messageID: "m1", accountID: account) } == nil)
        #expect(try await cache.read { tx in try tx.messageCalendar(messageID: "m1", accountID: account) } == nil)
    }

    @Test func aMessageDeletedDuringFetchCannotRegainItsBodyOrInvitation() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t1", [SystemLabel.inbox])], cursor: 100)
        await gmail.setThread(try thread([
            message("m1", parts: [plainPart("Surviving message"), inlineCalendar()]),
            message("m2", parts: [plainPart("Deleted message"), inlineCalendar()]),
        ]))
        await gmail.holdNextThread()
        let loading = Task { try await engine.openThread("t1") }
        while await !gmail.isHoldingThread { await Task.yield() }
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId":"120","history":[{"id":"110","messagesDeleted":[{"message":{"id":"m2","threadId":"t1"}}]}]}"#))
        try await engine.sync()
        await gmail.releaseThread()
        try await loading.value

        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1"])
        #expect(try await cache.read { tx in try tx.messageCalendar(messageID: "m1", accountID: account) } != nil)
        #expect(try await cache.read { tx in try tx.body(messageID: "m2", accountID: account) } == nil)
        #expect(try await cache.read { tx in try tx.messageCalendar(messageID: "m2", accountID: account) } == nil)
    }

    private func calendar() -> Data {
        Data([
            "BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:REQUEST", "BEGIN:VEVENT",
            "UID:meeting-1@example.invalid", "DTSTAMP:20261030T090000Z",
            "DTSTART:20261101T100000Z", "DURATION:PT1H", "SUMMARY:Meeting",
            "END:VEVENT", "END:VCALENDAR", "",
        ].joined(separator: "\r\n").utf8)
    }

    private func thread(_ messages: [String]) throws -> GmailThread {
        try decode(GmailThread.self, "{\"id\":\"t1\",\"messages\":[\(messages.joined(separator: ","))]}")
    }

    private func message(_ id: String, parts: [String]) -> String {
        """
        {"id":"\(id)","threadId":"t1","historyId":"100","labelIds":["INBOX"],
         "internalDate":"\(Int(baseDate.timeIntervalSince1970 * 1000))",
         "payload":{"mimeType":"multipart/mixed","parts":[\(parts.joined(separator: ","))]}}
        """
    }

    private func calendarPart(_ id: String, size: Int = 256) -> String {
        #"{"mimeType":"text/calendar","body":{"attachmentId":"\#(id)","size":\#(size)}}"#
    }

    private func plainPart(_ text: String) -> String {
        #"{"mimeType":"text/plain","body":{"data":"\#(encoded(Data(text.utf8)))"}}"#
    }

    private func inlineCalendar() -> String {
        #"{"mimeType":"text/calendar","body":{"data":"\#(encoded(calendar()))"}}"#
    }

    private func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
