import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct ReadingHydrationTests {
    @Test(arguments: [false, true])
    func textIsPublishedBeforeOptionalImagesAndLateImagesRespectNewerVersions(deleteMessage: Bool) async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try readableThread(image: true))
        await gmail.setAttachment("picture", data: Data([1, 2, 3]))
        await gmail.holdNextAttachment()
        let opening = Task { try await engine.openThread("t1", markRead: false) }
        while await !gmail.isHoldingAttachment { await Task.yield() }

        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Hello")
        #expect(try await cache.mimeResources(messageID: "m1", accountID: account).isEmpty)
        try await cache.write { tx in
            if deleteMessage {
                try tx.rebuildThreads(try tx.deleteMessages(ids: ["m1"], accountID: account), accountID: account)
            } else {
                var message = try #require(try tx.message(id: "m1", accountID: account))
                message.historyID += 1
                try tx.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox])])
                try tx.replaceMIMEResources([.init(accountID: account, messageID: "m1", contentID: "newer",
                    partID: "2", mimeType: "image/png", data: Data([9]))], messageID: "m1", accountID: account)
            }
        }
        await gmail.releaseAttachment()
        try await opening.value
        #expect(try await cache.mimeResources(messageID: "m1", accountID: account).map(\.contentID) == (deleteMessage ? [] : ["newer"]))
        if deleteMessage { #expect(try await cache.read { try $0.message(id: "m1", accountID: account) } == nil) }
    }

    @Test func concurrentReadersShareWorkAndACancelledReaderDoesNotCancelTheOther() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try readableThread())
        await gmail.holdNextThread()
        let first = Task { try await engine.openThread("t1", markRead: false) }
        while await !gmail.isHoldingThread { await Task.yield() }
        let second = Task { try await engine.openThread("t1", markRead: false) }
        while await engine.readingLoads["t1"]?.waiters.count != 2 { await Task.yield() }
        first.cancel()
        while await engine.readingLoads["t1"]?.waiters.count != 1 { await Task.yield() }
        await gmail.releaseThread()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        try await engine.refreshCalendarInvitations(threadID: "t1")
        try await engine.openThread("t1", markRead: false)
        try await engine.refreshCalendarInvitations(threadID: "t1")
        var timings: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            try await engine.openThread("t1", markRead: false)
            try await engine.refreshCalendarInvitations(threadID: "t1")
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("Cached open plus enrichment check median: \(timings.sorted()[timings.count / 2]) ms (20 opens, no network)")
        #expect(await gmail.fullThreadRequests == ["t1"])
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Hello")
    }

    @Test func aLabelChangeDuringHydrationKeepsNewLabelsAndStillPublishesTheBody() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, SystemLabel.unread])], cursor: 100)
        await gmail.setThread(try readableThread())
        await gmail.holdNextThread()
        let opening = Task { try await engine.openThread("t1", markRead: false) }
        while await !gmail.isHoldingThread { await Task.yield() }
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId":"201","history":[{"id":"200","labelsRemoved":[{"message":{"id":"m1","threadId":"t1"},"labelIds":["UNREAD"]}]}]}"#))
        try await engine.sync()
        await gmail.releaseThread()
        try await opening.value
        #expect(try await cache.read { try $0.message(id: "m1", accountID: account)?.historyID } == 200)
        #expect(try await cache.read { try $0.thread(id: "t1", accountID: account)?.isUnread } == false)
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Hello")
    }

    @Test func prefetchIsBoundedAndDoesNotRecordReadsOrOpens() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let ids = (1...5).map { "t\($0)" }
        try await seed(cache, ids.enumerated().map { ("m\($0.offset + 1)", $0.element, [SystemLabel.inbox, SystemLabel.unread]) })
        for index in 1...5 { await gmail.setThread(try readableThread(messageID: "m\(index)", threadID: "t\(index)")) }
        await engine.prefetchThreads(ids + ["t1"])
        await engine.prefetchTask?.value
        await engine.prefetchThreads(ids)
        await engine.prefetchTask?.value
        #expect(await gmail.fullThreadRequests == Array(ids.prefix(4)))
        #expect(await gmail.fullThreadPriorities.allSatisfy { $0 == .background })
        #expect(try await cache.read { try $0.allActions(accountID: account).isEmpty })
        #expect(try await cache.read { try $0.thread(id: "t1", accountID: account)?.isUnread } == true)
        #expect(try await cache.evictionCandidates(keeping: [], now: baseDate).allSatisfy { $0.lastOpenedAt == nil })
        try await engine.openThread("t1", markRead: false)
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(await gmail.fullThreadRequests.count == 4)
    }

    @Test func aReaderPromotesBackgroundHydrationAndCancellationLeavesNoLateBody() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, SystemLabel.unread])])
        await gmail.setThread(try readableThread())
        await gmail.holdNextThread()
        await engine.prefetchThreads(["t1"])
        while await !gmail.isHoldingThread { await Task.yield() }
        try await engine.openThread("t1", markRead: false)
        await gmail.releaseThread()
        await engine.prefetchTask?.value
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(await gmail.fullThreadPriorities == [.background, .interactive])
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Hello")

        try await seed(cache, [("m2", "t2", [SystemLabel.inbox])])
        await gmail.setThread(try readableThread(messageID: "m2", threadID: "t2"))
        await gmail.holdNextThread()
        await engine.prefetchThreads(["t2"])
        while await !gmail.isHoldingThread { await Task.yield() }
        await engine.prefetchThreads([])
        let stopping = Task { await engine.stop() }
        while await !engine.isStopped { await Task.yield() }
        await gmail.releaseThread()
        await stopping.value
        #expect(try await cache.read { try $0.body(messageID: "m2", accountID: account) } == nil)
    }

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
        {"id":"t1","messages":[{"id":"m1","threadId":"t1","historyId":"1","labelIds":["INBOX"],"internalDate":"1900000000000",
          "payload":{"mimeType":"multipart/related","parts":[
          {"partId":"1","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<logo>"}],"body":{"data":"AQID","size":3}}
        ]}}]}
        """#))
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(try await cache.mimeResources(messageID: "m1", accountID: account).first?.contentID == "logo")
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Cached")
        #expect(await gmail.attachmentRequests.isEmpty)
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(await gmail.fullThreadRequests == ["t1"])

        // The mark outlives the engine, so the next launch asks for nothing.
        let (relaunched, _, coldGmail, _) = try await makeEngine(cache: cache)
        try await relaunched.refreshCalendarInvitations(threadID: "t1")
        #expect(await coldGmail.fullThreadRequests.isEmpty)
    }

    @Test func aRelaunchOpensACachedConversationWithoutARequest() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try readableThread(image: true))
        await gmail.setAttachment("picture", data: Data([1, 2, 3]))
        try await engine.openThread("t1", markRead: false)
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(await gmail.fullThreadRequests == ["t1"])
        #expect(try await cache.read { try $0.bodyEnrichedAt(messageID: "m1", accountID: account) } != nil)

        let (relaunched, _, coldGmail, _) = try await makeEngine(cache: cache)
        try await relaunched.openThread("t1", markRead: false)
        try await relaunched.refreshCalendarInvitations(threadID: "t1")
        #expect(await coldGmail.fullThreadRequests.isEmpty)
        #expect(await coldGmail.attachmentRequests.isEmpty)
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Hello")
        #expect(try await cache.mimeResources(messageID: "m1", accountID: account).map(\.contentID) == ["logo"])
    }

    @Test func aNewMessageInACachedConversationFetchesOnlyItsOwnParts() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try readableThread(image: true))
        await gmail.setAttachment("picture", data: Data([1, 2, 3]))
        try await engine.openThread("t1", markRead: false)
        #expect(await gmail.attachmentRequests == ["picture"])

        // A sync pass brings the reply's metadata; its body is still to fetch.
        try await seed(cache, [("m2", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try decode(GmailThread.self, #"""
        {"id":"t1","messages":[
          {"id":"m1","threadId":"t1","historyId":"100","labelIds":["INBOX"],"internalDate":"1900000000000",
           "payload":{"mimeType":"multipart/related","parts":[
             {"partId":"0","mimeType":"text/plain","body":{"data":"SGVsbG8"}},
             {"partId":"1","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<logo>"}],"body":{"attachmentId":"picture","size":3}}]}},
          {"id":"m2","threadId":"t1","historyId":"101","labelIds":["INBOX"],"internalDate":"1900000060000",
           "payload":{"mimeType":"multipart/related","parts":[
             {"partId":"0","mimeType":"text/plain","body":{"data":"UmVwbHk"}},
             {"partId":"1","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<reply>"}],"body":{"attachmentId":"picture2","size":3}}]}}]}
        """#))
        await gmail.setAttachment("picture2", data: Data([4, 5, 6]))
        try await engine.openThread("t1", markRead: false)
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(await gmail.fullThreadRequests == ["t1", "t1"])
        #expect(await gmail.attachmentRequests == ["picture", "picture2"])
        #expect(try await cache.read { try $0.body(messageID: "m2", accountID: account)?.plainText } == "Reply")
        #expect(try await cache.mimeResources(messageID: "m1", accountID: account).map(\.contentID) == ["logo"])
        #expect(try await cache.mimeResources(messageID: "m2", accountID: account).map(\.contentID) == ["reply"])
    }

    @Test func aPictureGmailNoLongerHasDoesNotKeepTheConversationRefetching() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        // The picture's attachment is never registered, so Gmail answers not found.
        await gmail.setThread(try readableThread(image: true))
        try await engine.openThread("t1", markRead: false)
        try await engine.refreshCalendarInvitations(threadID: "t1")
        try await engine.refreshCalendarInvitations(threadID: "t1")
        #expect(await gmail.fullThreadRequests == ["t1"])
        #expect(await gmail.attachmentRequests == ["picture"])
        #expect(try await cache.read { try $0.body(messageID: "m1", accountID: account)?.plainText } == "Hello")
        #expect(try await cache.mimeResources(messageID: "m1", accountID: account).isEmpty)
    }

    private func readableThread(messageID: String = "m1", threadID: String = "t1", image: Bool = false) throws -> GmailThread {
        let picture = image ? #",{"partId":"1","mimeType":"image/png","headers":[{"name":"Content-ID","value":"<logo>"}],"body":{"attachmentId":"picture","size":3}}"# : ""
        return try decode(GmailThread.self, """
        {"id":"\(threadID)","messages":[{"id":"\(messageID)","threadId":"\(threadID)","historyId":"100","labelIds":["INBOX","UNREAD"],
          "internalDate":"1900000000000","payload":{"mimeType":"multipart/related","parts":[
            {"partId":"0","mimeType":"text/plain","body":{"data":"SGVsbG8"}}\(picture)
          ]}}]}
        """)
    }
}
