import Foundation
import GmailAPI
import MailStore
import Testing
@testable import SyncEngine

@Suite struct AssistantWritingSamplesTests {
    @Test func selectsOneHundredMessagesAcrossPagesWithoutCollapsingTheirThread() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("cached", "cached-thread", [SystemLabel.inbox, SystemLabel.unread])])
        for index in 0..<105 { await gmail.add(try writingMessage("m\(index)", date: 1_000_000 - index)) }
        await gmail.setRecentPages([
            try writingPage((0..<60).map { "m\($0)" } + ["m0"], next: "next"),
            try writingPage((60..<105).map { "m\($0)" }, next: "older")
        ])
        let result = try await engine.assistantWritingSamples()
        #expect(result.accountID == account)
        #expect(result.requestedCount == 100)
        #expect(result.selectedCount == 100)
        #expect(result.inspectedCount == 100)
        #expect(result.samples.count == 100)
        #expect(result.skippedCount == 0)
        #expect(result.samples.first?.messageID == "m0")
        #expect(result.samples.last?.messageID == "m99")
        #expect(result.hasMoreSentMail)
        #expect(!result.truncated)
        #expect(Set(await gmail.metadataRequests.flatMap { $0 }).count == 100)
        #expect(try await cache.read { try $0.thread(id: "cached-thread", accountID: account) }?.isUnread == true)
        #expect(try await cache.read { try $0.thread(id: "same-thread", accountID: account) } == nil)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
        #expect(await gmail.changes.isEmpty)
    }

    @Test func reportsMissingNonSentShortAndUnavailableBodiesTruthfully() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try writingMessage("good"))
        await gmail.add(try writingMessage("short", text: "OK"))
        await gmail.add(try writingMessage("not-sent", sent: false))
        await gmail.add(try writingMessage("body-failure", externalBody: "missing-part"))
        await gmail.setRecentPages([try writingPage(["good", "short", "missing", "not-sent", "body-failure"])])
        let result = try await engine.assistantWritingSamples()
        #expect(result.selectedCount == 5)
        #expect(result.inspectedCount == 3)
        #expect(result.samples.map(\.messageID) == ["good"])
        #expect(result.skippedCount == 2)
        #expect(Set(result.failures.map(\.reason)) == [.messageUnavailable, .invalidMessage, .bodyUnavailable])
        #expect(result.truncated)
        #expect(!result.hasMoreSentMail)
    }

    @Test func downloadsOnlyBoundedBodyPartsAndNeverFileAttachments() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try writingMessage("external", externalBody: "body", fileAttachment: true))
        await gmail.setAttachment("body", data: Data("Please review the revised notes when you have time.".utf8))
        await gmail.setAttachment("file", data: Data("Attached writing must never become a style sample.".utf8))
        await gmail.setRecentPages([try writingPage(["external"])])
        let result = try await engine.assistantWritingSamples()
        #expect(result.samples.count == 1)
        #expect(await gmail.attachmentRequests == ["body"])
        #expect(!result.samples[0].text.contains("Attached writing"))
        #expect(await gmail.changes.isEmpty)
    }

    @Test func revokedAccessRejectsAFullResponseThatArrivesLate() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try writingMessage("held"))
        await gmail.setRecentPages([try writingPage(["held"])])
        await gmail.holdNextMetadata()
        let access = WritingAccess()
        let task = Task { try await engine.assistantWritingSamples { await access.allowed } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gmail.isHoldingMetadata), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gmail.isHoldingMetadata)
        await access.revoke()
        await gmail.releaseMetadata()
        await #expect(throws: AssistantMailError.accessChanged) { try await task.value }
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
        #expect(await gmail.changes.isEmpty)
    }

    @Test func oversizedInlineAndExternalBodiesAreSkippedBeforePartDownloads() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try writingMessage("inline", text: String(repeating: "a", count: 131_073)))
        await gmail.add(try writingMessage("external", externalBody: "large", externalSize: 131_073))
        await gmail.setRecentPages([try writingPage(["inline", "external"])])
        let result = try await engine.assistantWritingSamples()
        #expect(result.inspectedCount == 2)
        #expect(result.skippedCount == 2)
        #expect(result.samples.isEmpty)
        #expect(result.failures.map(\.reason) == [.bodyTooLarge, .bodyTooLarge])
        #expect(result.truncated)
        #expect(await gmail.attachmentRequests.isEmpty)
    }

    @Test func repeatedPaginationTokensStopWithExplicitCoverage() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try writingMessage("one"))
        await gmail.setRecentPages([
            try writingPage(["one"], next: "repeat"), try writingPage(["one"], next: "repeat"),
            try writingPage(["never-read"])
        ])
        let result = try await engine.assistantWritingSamples()
        #expect(result.selectedCount == 1)
        #expect(result.inspectedCount == 1)
        #expect(result.failures.map(\.reason) == [.repeatedPageToken])
        #expect(result.truncated)
        #expect(result.hasMoreSentMail)
    }

    @Test func excerptByteBudgetDoesNotPretendUninspectedMailWasRead() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        let ids = (0..<100).map { "long-\($0)" }
        for id in ids { await gmail.add(try writingMessage(id, text: String(repeating: "ä", count: 2_000))) }
        await gmail.setRecentPages([try writingPage(ids)])
        let result = try await engine.assistantWritingSamples()
        #expect(result.inspectedCount == 100)
        #expect(result.samples.count == 40)
        #expect(result.skippedCount == 60)
        #expect(result.samples.reduce(0) { $0 + $1.text.utf8.count } == 81_920)
        #expect(result.samples.allSatisfy { $0.text.utf8.count <= 2_048 && $0.truncated })
        #expect(result.failures.filter { $0.reason == .excerptLimit }.count == 60)
        #expect(result.truncated)
        #expect(await gmail.metadataRequests.count == 10)
        #expect(await gmail.attachmentRequests.isEmpty)
    }

    @Test func uniquePaginationTokensStillRespectThePageLimit() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try writingMessage("one"))
        var pages = try (1...5).map { try writingPage(["one"], next: "page-\($0)") }
        pages.append(try writingPage(["never-read"]))
        await gmail.setRecentPages(pages)
        let result = try await engine.assistantWritingSamples()
        #expect(result.selectedCount == 1)
        #expect(result.inspectedCount == 1)
        #expect(result.failures.map(\.reason) == [.pageLimit])
        #expect(result.hasMoreSentMail)
        #expect(result.truncated)
    }
}

private actor WritingAccess {
    private(set) var allowed = true
    func revoke() { allowed = false }
}

private func writingPage(_ ids: [String], next: String? = nil) throws -> MessageListPage {
    var value: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": "same-thread"] }]
    value["nextPageToken"] = next
    return try JSONDecoder().decode(MessageListPage.self, from: JSONSerialization.data(withJSONObject: value))
}

private func writingMessage(_ id: String, text: String = "Hello team,\n\nPlease review the updated notes when you have time.\n\nThanks,\nMy Name",
                            date: Int = 1_000_000, sent: Bool = true, externalBody: String? = nil,
                            externalSize: Int = 100, fileAttachment: Bool = false) throws -> GmailMessage {
    let body: [String: Any] = externalBody.map { ["attachmentId": $0, "size": externalSize] }
        ?? ["data": Data(text.utf8).base64EncodedString(), "size": text.utf8.count]
    var payload: [String: Any] = ["mimeType": "text/plain", "partId": "0", "body": body]
    if fileAttachment {
        payload = ["mimeType": "multipart/mixed", "parts": [payload,
            ["mimeType": "text/plain", "partId": "1", "filename": "notes.txt", "body": ["attachmentId": "file", "size": 100]]]]
    }
    let value: [String: Any] = ["id": id, "threadId": "same-thread", "historyId": "100", "internalDate": String(date),
                              "labelIds": sent ? ["SENT", "UNREAD"] : ["INBOX"], "payload": payload]
    return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: value))
}
