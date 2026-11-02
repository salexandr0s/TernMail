import Foundation
import GmailAPI
import MailStore
import Testing
@testable import SyncEngine

@Suite struct MailOrganizationSamplesTests {
    @Test func samples250CombinedMessagesAndKeepsExactMessageMetadataWithoutWritingGmail() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("older", "shared", [SystemLabel.inbox, SystemLabel.unread])], cursor: 90)
        for index in 0..<260 {
            await gmail.add(try organizationMessage("m\(index)", labels: index.isMultiple(of: 2) ? ["SENT"] : ["INBOX", "UNREAD"],
                                                      date: 1_000_000 - index))
        }
        await gmail.setRecentPages([
            try organizationPage((0..<150).map { "m\($0)" } + ["m0"], next: "more"),
            try organizationPage((150..<260).map { "m\($0)" })
        ])
        let progress = OrganizationProgressRecorder()
        let samples = try await engine.organizationSamples(progress: { await progress.append($0) })
        #expect(samples.accountID == account)
        #expect(samples.selectedCount == 250)
        #expect(samples.messages.count == 250)
        #expect(samples.messages.filter(\.isSent).count == 125)
        #expect(samples.messages.first?.messageID == "m0")
        #expect(samples.messages.last?.messageID == "m249")
        #expect(samples.messages.first?.sender == "sender@example.com")
        #expect(samples.messages.first?.recipients == ["me@example.com"])
        #expect(samples.messages.first?.snippet == "News & updates")
        #expect(!samples.isPartial)
        #expect(samples.unavailableCount == 0)
        #expect(await gmail.metadataRequests.count == 10)
        #expect(await gmail.attachmentRequests.isEmpty)
        #expect(await gmail.changes.isEmpty)
        #expect(try await cache.read { try $0.messages(threadID: "shared", accountID: account) }.count == 251)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
        #expect(try await cache.read { try $0.syncState(accountID: account) }?.historyID == 90)
        #expect(try await cache.read { try $0.heldThreadIDs(accountID: account) } == ["shared"])
        let updates = await progress.values
        #expect(updates.first == .init(stage: .labels))
        #expect(updates.filter { $0.stage == .listing }.map(\.selectedCount) == [0, 150, 250])
        #expect(updates.filter { $0.stage == .reading }.map(\.processedCount) == Array(stride(from: 0, through: 250, by: 25)))
        #expect(updates.filter { $0.stage == .reading }.allSatisfy { $0.selectedCount == 250 })
    }

    @Test func excludesIneligibleAndMissingMailWithExplicitPartialCoverage() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        for (id, labels) in [("good", ["INBOX"]), ("draft", ["DRAFT"]), ("spam", ["SPAM"]), ("trash", ["TRASH"])] {
            await gmail.add(try organizationMessage(id, labels: labels))
        }
        await gmail.setRecentPages([try organizationPage(["good", "draft", "spam", "trash", "missing"])])
        let progress = OrganizationProgressRecorder()
        let samples = try await engine.organizationSamples(progress: { await progress.append($0) })
        #expect(samples.messages.map(\.messageID) == ["good"])
        #expect(samples.selectedCount == 5)
        #expect(samples.unavailableCount == 4)
        #expect(samples.isPartial)
        #expect(await gmail.changes.isEmpty)
        #expect(await progress.values.last == .init(stage: .reading, processedCount: 5, selectedCount: 5))
    }

    @Test func cancellationAfterMetadataResponseDoesNotCacheOrReturnPrivateSamples() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try organizationMessage("held"))
        await gmail.setRecentPages([try organizationPage(["held"])])
        await gmail.holdNextMetadata()
        let access = OrganizationSampleAccess()
        let task = Task { try await engine.organizationSamples(isAuthorized: { await access.allowed }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gmail.isHoldingMetadata), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gmail.isHoldingMetadata)
        await access.revoke()
        await gmail.releaseMetadata()
        await #expect(throws: AssistantMailError.accessChanged) { try await task.value }
        #expect(try await cache.read { try $0.message(id: "held", accountID: account) } == nil)
        #expect(await gmail.changes.isEmpty)
    }

    @Test func permissionRevokedDuringProgressStopsTheNextNetworkRequest() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        let access = OrganizationSampleAccess()
        await #expect(throws: AssistantMailError.accessChanged) {
            try await engine.organizationSamples(isAuthorized: { await access.allowed }, progress: { _ in
                await access.revoke()
            })
        }
        #expect(await gmail.labelListRequests == 0)
        #expect(await gmail.metadataRequests.isEmpty)
        #expect(await gmail.changes.isEmpty)
    }

    @Test func repeatedPageTokenTerminatesAndTextBoundsPreserveUnicode() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try organizationMessage("one", subject: String(repeating: "€", count: 300),
                                               snippet: String(repeating: "é", count: 700)))
        await gmail.setRecentPages([try organizationPage(["one"], next: "repeat"),
                                    try organizationPage(["one"], next: "repeat")])
        let samples = try await engine.organizationSamples()
        #expect(samples.messages.count == 1)
        #expect(samples.isPartial)
        #expect(samples.messages[0].subject.utf8.count <= MailOrganizationSampleLimits.subjectBytes)
        #expect(samples.messages[0].snippet.utf8.count <= MailOrganizationSampleLimits.snippetBytes)
        #expect(!samples.messages[0].subject.contains("�"))
    }

    @Test func deletedMailCannotReturnFromAnInflightMetadataResponse() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try organizationMessage("deleted"))
        await gmail.add(try organizationMessage("live"))
        await gmail.setRecentPages([try organizationPage(["deleted", "live"])])
        await gmail.holdNextMetadata()
        let task = Task { try await engine.organizationSamples() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gmail.isHoldingMetadata), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gmail.isHoldingMetadata)
        let deleted = await engine.deletedMessageIDs
        deleted.withLock { _ = $0.insert("deleted") }
        await gmail.releaseMetadata()
        let result = try await task.value
        #expect(result.messages.map(\.messageID) == ["live"])
        #expect(result.unavailableCount == 1 && result.isPartial)
        #expect(try await cache.read { try $0.message(id: "deleted", accountID: account) } == nil)
        #expect(await gmail.changes.isEmpty)
    }
}

private actor OrganizationSampleAccess {
    private(set) var allowed = true
    func revoke() { allowed = false }
}

private actor OrganizationProgressRecorder {
    private(set) var values: [MailOrganizationSamplingProgress] = []
    func append(_ value: MailOrganizationSamplingProgress) { values.append(value) }
}

private func organizationPage(_ ids: [String], next: String? = nil) throws -> MessageListPage {
    var object: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": "shared"] }]
    object["nextPageToken"] = next
    return try JSONDecoder().decode(MessageListPage.self, from: JSONSerialization.data(withJSONObject: object))
}

private func organizationMessage(_ id: String, labels: [String] = ["INBOX"], date: Int = 1_000_000,
                                 subject: String = "Weekly news", snippet: String = "News &amp; updates") throws -> GmailMessage {
    let object: [String: Any] = [
        "id": id, "threadId": "shared", "historyId": "100", "internalDate": String(date),
        "labelIds": labels, "snippet": snippet,
        "payload": ["headers": [["name": "From", "value": "Sender <sender@example.com>"],
                                 ["name": "To", "value": "Me <me@example.com>"],
                                 ["name": "Subject", "value": subject]]]
    ]
    return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: object))
}
