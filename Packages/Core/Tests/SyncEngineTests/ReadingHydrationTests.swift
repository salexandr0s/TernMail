import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct ReadingHydrationTests {
    @Test func manualOpeningKeepsUnreadAndCommitsOnlyBoundedMessageImagesWithTheBody() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, SystemLabel.unread])])
        let thread = try decode(GmailThread.self, #"""
        {"id":"t1","messages":[{"id":"m1","threadId":"t1","historyId":"100","labelIds":["INBOX","UNREAD"],
          "internalDate":"1900000000000","payload":{"mimeType":"multipart/related","parts":[
            {"partId":"0","mimeType":"text/plain","body":{"data":"SGVsbG8"}},
            {"partId":"1","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<logo>"}],"body":{"attachmentId":"picture","size":3}},
            {"partId":"2","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<huge>"}],"body":{"attachmentId":"never-download","size":5242881}}
          ]}}]}
        """#)
        await gmail.setThread(thread)
        await gmail.setAttachment("picture", data: Data([1, 2, 3]))
        try await engine.openThread("t1", markRead: false)
        #expect(try await cache.read { try $0.allActions(accountID: account).isEmpty })
        #expect(try await cache.read { try $0.thread(id: "t1", accountID: account)?.isUnread } == true)
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Hello")
        let pictures = try await cache.mimeResources(messageID: "m1", accountID: account)
        #expect(pictures.map(\.contentID) == ["logo"])
        #expect(pictures.first?.data == Data([1, 2, 3]))
        #expect(await gmail.attachmentRequests == ["picture"])
    }

    @Test func calendarBackfillAlsoHydratesImagesForBodiesCachedBeforeInlineSupport() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        try await cache.write { tx in
            try tx.saveBodies([MessageBodyRecord(accountID: account, messageID: "m1", html: nil, plainText: "Cached", fetchedAt: baseDate)])
        }
        await gmail.setThread(try decode(GmailThread.self, #"""
        {"id":"t1","messages":[{"id":"m1","threadId":"t1","payload":{"mimeType":"multipart/related","parts":[
          {"partId":"1","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<logo>"}],"body":{"data":"AQID","size":3}}
        ]}}]}
        """#))
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(try await cache.mimeResources(messageID: "m1", accountID: account).first?.contentID == "logo")
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Cached")
        #expect(await gmail.attachmentRequests.isEmpty)
    }
}
