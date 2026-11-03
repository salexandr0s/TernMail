import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct AttachmentIndexingTests {
    @Test func historicalPagesResumeWithoutDownloadingOrDuplicatingOccurrences() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "index.sqlite")
        let cache = try MailCache.open(at: url)
        let gmail = LibraryGmail()
        try await gmail.setPage(nil, ids: ["old"], next: "older")
        try await gmail.setPage("older", ids: ["older", "old"], next: nil)
        await gmail.add(try libraryMessage("old", includingInline: true))
        await gmail.add(try libraryMessage("older"))
        let engine = libraryEngine(cache: cache, gmail: gmail)
        let partial = try await engine.indexAttachments()
        #expect(!partial.isComplete)
        #expect(partial.nextPageToken == "older")
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 1)
        await engine.stop()

        let reopened = try MailCache.open(at: url)
        let restarted = libraryEngine(cache: reopened, gmail: gmail)
        let complete = try await restarted.indexAttachments()
        #expect(complete.isComplete)
        #expect(complete.nextPageToken == nil)
        #expect(await gmail.listTokens == ["first", "older"])
        #expect(await gmail.listQueries == ["has:attachment", "has:attachment"])
        #expect(await gmail.listIncludesSpamTrash.allSatisfy { $0 })
        #expect(await gmail.listLimits == [25, 25])
        let items = try await reopened.attachmentLibrary(query: .init(accountIDs: [account])).items
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(items.allSatisfy { $0.filename == "invoice.pdf" })
        #expect(await gmail.downloadRequests == 0)
        #expect(try await reopened.read { try $0.cachedMessageIDs(accountID: account) }.isEmpty)
    }

    @Test func failedPageKeepsCheckpointAndBackoffUntilExplicitRetry() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        try await gmail.setPage(nil, ids: ["one", "two"], next: "next")
        await gmail.add(try libraryMessage("one"))
        await gmail.add(try libraryMessage("two"))
        await gmail.failMetadata("two", with: .rateLimited)
        let engine = libraryEngine(cache: cache, gmail: gmail)
        await #expect(throws: GmailError.rateLimited) { try await engine.indexAttachments() }
        let failed = try #require(try await cache.read { try $0.attachmentIndexState(accountID: account) })
        #expect(failed.nextPageToken == nil)
        #expect(failed.indexedMessageCount == 0)
        #expect(failed.lastError != nil)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 0)
        _ = try await engine.indexAttachments()
        #expect(await gmail.listTokens.count == 1)
        await gmail.failMetadata("two", with: nil)
        let retried = try await engine.indexAttachments(retryNow: true)
        #expect(retried.nextPageToken == "next")
        #expect(retried.lastError == nil)
        #expect(retried.failureCount == 0)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 2)
    }

    @Test func bulkHistoryIsBoundedAndResumesItsDurableQueue() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        let engine = libraryEngine(cache: cache, gmail: gmail)
        _ = try await engine.indexAttachments()
        let ids = (0..<51).map { "m\($0)" }
        for id in ids { await gmail.add(try libraryMessage(id)) }
        await gmail.queueHistory(try historyJSON(added: ids, historyID: 300))
        let first = try await engine.indexAttachments()
        #expect(first.pendingMessageIDs.count == 26)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 25)
        await engine.stop()
        let restarted = libraryEngine(cache: cache, gmail: gmail)
        let second = try await restarted.indexAttachments()
        #expect(second.pendingMessageIDs.count == 1)
        let third = try await restarted.indexAttachments()
        #expect(third.pendingMessageIDs.isEmpty)
        #expect(await gmail.metadataRequests.map(\.count) == [25, 25, 1])
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 51)

        await gmail.queueHistory(try decode(HistoryPage.self, #"""
            {"historyId":"400","history":[{"id":"400",
              "messagesDeleted":[{"message":{"id":"m0","threadId":"thread-m0"}}],
              "labelsAdded":[{"message":{"id":"m1","threadId":"thread-m1"},"labelIds":["paid"]}]}]}
            """#))
        _ = try await restarted.indexAttachments()
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 50)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account], label: .init(accountID: account, id: "paid"))).items.map(\.messageID) == ["m1"])
        #expect(await gmail.downloadRequests == 0)
    }

    @Test func expiredHistoryReconcilesOldRowsAndKeepsCategoryCorrections() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        try await gmail.setPage(nil, ids: ["gone", "kept"], next: nil)
        await gmail.add(try libraryMessage("gone"))
        await gmail.add(try libraryMessage("kept"))
        let engine = libraryEngine(cache: cache, gmail: gmail)
        _ = try await engine.indexAttachments()
        try await cache.write { try $0.setAttachmentCategory(.invoice, accountID: account, messageID: "kept", partID: "1") }
        try await gmail.setPage(nil, ids: ["kept"], next: "last")
        try await gmail.setPage("last", ids: [], next: nil)
        await gmail.expireNextHistory()
        let restarted = try await engine.indexAttachments()
        #expect(!restarted.isComplete)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 2)
        _ = try await engine.indexAttachments()
        let items = try await cache.attachmentLibrary(query: .init(accountIDs: [account])).items
        #expect(items.map(\.messageID) == ["kept"])
        #expect(items.first?.category == .invoice)
    }

    @Test func truncatedMetadataAndStoppedFetchNeverClaimCompleteCoverage() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        var tree: [String: Any] = ["mimeType": "multipart/mixed", "partId": "20"]
        for index in (0..<20).reversed() { tree = ["mimeType": "multipart/mixed", "partId": "\(index)", "parts": [tree]] }
        let json: [String: Any] = ["id": "deep", "threadId": "thread-deep", "historyId": "200", "payload": tree]
        await gmail.add(try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: json)))
        try await gmail.setPage(nil, ids: ["deep"], next: nil)
        let engine = libraryEngine(cache: cache, gmail: gmail)
        await #expect(throws: GmailError.self) { try await engine.indexAttachments() }
        let failed = try #require(try await cache.read { try $0.attachmentIndexState(accountID: account) })
        #expect(!failed.isComplete)
        #expect(failed.lastError != nil)

        await gmail.add(try libraryMessage("deep"))
        await gmail.holdNextMetadata()
        let pending = Task { try await engine.indexAttachments(retryNow: true) }
        while !(await gmail.isHoldingMetadata) { await Task.yield() }
        let stopping = Task { await engine.stop() }
        while !(await engine.isStopped) { await Task.yield() }
        await gmail.releaseMetadata()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [account])).totalCount == 0)
    }

    @Test func sourceHydrationUsesTheNormalReaderCacheWithoutOpeningUnrelatedMail() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        await gmail.add(try libraryMessage("old"))
        let engine = libraryEngine(cache: cache, gmail: gmail)
        try await engine.loadAttachmentSource("thread-old")
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: account) } == ["old"])
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: "other") }.isEmpty)
        await #expect(throws: AssistantMailError.unavailable) { try await engine.loadAttachmentSource("missing") }
    }

    @Test func downloadsRejectCrossAccountRecordsAndBoundDisposableFiles() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = libraryEngine(cache: cache, gmail: gmail)
        let other = libraryEngine(cache: cache, gmail: gmail, accountID: "other")
        let record = AttachmentRecord(accountID: account, messageID: "../m", partID: "../../1", attachmentID: "data",
            filename: "../invoice.pdf", mimeType: "application/pdf", size: 4, isInline: false)
        let url = try await engine.downloadAttachment(record, into: directory)
        #expect(url.standardizedFileURL.path.hasPrefix(directory.path + "/"))
        #expect(try Data(contentsOf: url) == Data("file".utf8))
        await #expect(throws: GmailError.self) { try await other.downloadAttachment(record, into: directory) }
        #expect(await gmail.downloadRequests == 1)
        let otherRecord = AttachmentRecord(accountID: "other", messageID: record.messageID, partID: record.partID,
            attachmentID: "data", filename: record.filename, mimeType: record.mimeType, size: 4, isInline: false)
        let otherURL = try await other.downloadAttachment(otherRecord, into: directory)
        #expect(otherURL != url)
        let disposable = directory.appending(path: "disposable.txt")
        try Data("file".utf8).write(to: disposable)
        try AttachmentFileCache.prune(directory, keeping: otherURL, now: Date(), maximumBytes: 4,
            protectedURLs: [url.standardizedFileURL.resolvingSymlinksInPath()])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: otherURL.path))
        #expect(!FileManager.default.fileExists(atPath: disposable.path))
        // Closing the preview makes its file disposable again on the next pass.
        try AttachmentFileCache.prune(directory, keeping: otherURL, now: Date(), maximumBytes: 4)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: otherURL.path))
        #expect(SyncEngine.safeFilename(String(repeating: "🪶", count: 500) + ".pdf").utf8.count <= 220)
        await engine.stop()
        await #expect(throws: CancellationError.self) { try await engine.downloadAttachment(record, into: directory) }
    }

    @Test func previewProtectionIsReadAfterTheDownloadAndAgainForCacheReuse() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = libraryEngine(cache: cache, gmail: gmail)
        let record = AttachmentRecord(accountID: account, messageID: "m", partID: "1", attachmentID: "data",
            filename: "invoice.pdf", mimeType: "application/pdf", size: 4, isInline: false)
        let previous = directory.appending(path: "previous.pdf")
        let current = directory.appending(path: "current.pdf")
        let protection = LibraryPreviewProtection(urls: [previous])
        await gmail.holdNextDownload()
        let pending = Task {
            try await engine.downloadAttachment(record, into: directory, protectedURLs: { await protection.values() })
        }
        while !(await gmail.isHoldingDownload) { await Task.yield() }
        #expect(await protection.reads.isEmpty)
        await protection.setURLs([current])
        await gmail.releaseDownload()
        _ = try await pending.value
        #expect(await protection.reads == [[current]])
        await protection.setURLs([])
        _ = try await engine.downloadAttachment(record, into: directory, protectedURLs: { await protection.values() })
        #expect(await protection.reads == [[current], []])
        #expect(await gmail.downloadRequests == 1)
        await engine.stop()
    }

    @Test(arguments: [false, true])
    func cancellationWhileReadingPreviewProtectionDoesNotPrune(fromCache: Bool) async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = libraryEngine(cache: cache, gmail: gmail)
        let record = AttachmentRecord(accountID: account, messageID: "m", partID: "1", attachmentID: "data",
            filename: "invoice.pdf", mimeType: "application/pdf", size: 4, isInline: false)
        if fromCache { _ = try await engine.downloadAttachment(record, into: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expired = directory.appending(path: "expired.txt")
        try Data("old".utf8).write(to: expired)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: expired.path)
        let protection = LibraryPreviewProtection(holdRead: true)
        let pending = Task {
            try await engine.downloadAttachment(record, into: directory, protectedURLs: { await protection.values() })
        }
        while !(await protection.isHoldingRead) { await Task.yield() }
        pending.cancel()
        await protection.releaseRead()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(FileManager.default.fileExists(atPath: expired.path))
        await engine.stop()
    }

    @Test func signOutWaitsForDownloadAndPreventsRecreatingItsCache() async throws {
        let cache = try MailCache.inMemory()
        let gmail = LibraryGmail()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = libraryEngine(cache: cache, gmail: gmail)
        let record = AttachmentRecord(accountID: account, messageID: "m", partID: "1", attachmentID: "data",
            filename: "invoice.pdf", mimeType: "application/pdf", size: 4, isInline: false)
        await gmail.holdNextDownload()
        let pending = Task { try await engine.downloadAttachment(record, into: directory) }
        while !(await gmail.isHoldingDownload) { await Task.yield() }
        let stopping = Task { await engine.stop() }
        while !(await engine.isStopped) { await Task.yield() }
        await gmail.releaseDownload()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

private actor LibraryPreviewProtection {
    private var urls: Set<URL>
    private let holdRead: Bool
    private var heldRead: CheckedContinuation<Void, Never>?
    private(set) var reads: [Set<URL>] = []

    init(urls: Set<URL> = [], holdRead: Bool = false) {
        self.urls = urls
        self.holdRead = holdRead
    }

    func setURLs(_ urls: Set<URL>) { self.urls = urls }
    var isHoldingRead: Bool { heldRead != nil }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    func values() async -> Set<URL> {
        if holdRead { await withCheckedContinuation { heldRead = $0 } }
        reads.append(urls)
        return urls
    }
}

private func libraryEngine(cache: MailCache, gmail: LibraryGmail, accountID: String = account) -> SyncEngine {
    SyncEngine(accountID: accountID, sender: EmailAddress(address: "user@example.test"),
        outgoingDirectory: FileManager.default.temporaryDirectory, gmail: gmail, cache: cache, sendsAutomatically: false)
}

private func libraryMessage(_ id: String, includingInline: Bool = false) throws -> GmailMessage {
    let inline = includingInline ? #",{"partId":"2","mimeType":"image/png","filename":"logo.png","headers":[{"name":"Content-ID","value":"<logo>"},{"name":"Content-Disposition","value":"attachment"}],"body":{"attachmentId":"logo","size":10}}"# : ""
    return try decode(GmailMessage.self, #"""
        {"id":"\#(id)","threadId":"thread-\#(id)","historyId":"200","internalDate":"1500000000000","labelIds":["INBOX"],
         "payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"Studio <billing@example.test>"},
          {"name":"Subject","value":"Annual invoice"}],"parts":[
          {"partId":"1","mimeType":"application/pdf","filename":"invoice.pdf","body":{"attachmentId":"file-\#(id)","size":4}}\#(inline)]}}
        """#)
}

private func historyJSON(added ids: [String], historyID: Int) throws -> HistoryPage {
    let entries = ids.map { ["message": ["id": $0, "threadId": "thread-\($0)"]] }
    let json: [String: Any] = ["historyId": String(historyID), "history": [["id": String(historyID), "messagesAdded": entries]]]
    return try JSONDecoder().decode(HistoryPage.self, from: JSONSerialization.data(withJSONObject: json))
}

/// Keeps list pages by token so a test cannot pass after skipping or restarting
/// a page accidentally. Other mail operations delegate to the existing fixture.
private actor LibraryGmail: GmailService {
    let base = FakeGmail()
    var pages: [String: MessageListPage] = [:]
    var historyPages: [HistoryPage] = []
    var metadata: [String: GmailMessage] = [:]
    var metadataErrors: [String: GmailError] = [:]
    var expiresHistory = false
    var holdsMetadata = false
    var heldMetadata: CheckedContinuation<Void, Never>?
    var holdsDownload = false
    var heldDownload: CheckedContinuation<Void, Never>?
    private(set) var listTokens: [String] = []
    private(set) var listQueries: [String] = []
    private(set) var listIncludesSpamTrash: [Bool] = []
    private(set) var listLimits: [Int] = []
    private(set) var metadataRequests: [[String]] = []
    private(set) var downloadRequests = 0

    func setPage(_ token: String?, ids: [String], next: String?) throws {
        var json: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": "thread-\($0)"] }]
        if let next { json["nextPageToken"] = next }
        pages[token ?? "first"] = try JSONDecoder().decode(MessageListPage.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func add(_ message: GmailMessage) { metadata[message.id] = message }
    func failMetadata(_ id: String, with error: GmailError?) { metadataErrors[id] = error }
    func queueHistory(_ page: HistoryPage) { historyPages.append(page) }
    func expireNextHistory() { expiresHistory = true }
    func holdNextMetadata() { holdsMetadata = true }
    var isHoldingMetadata: Bool { heldMetadata != nil }
    func releaseMetadata() { heldMetadata?.resume(); heldMetadata = nil }
    func holdNextDownload() { holdsDownload = true }
    var isHoldingDownload: Bool { heldDownload != nil }
    func releaseDownload() { heldDownload?.resume(); heldDownload = nil }
    func profile() async throws -> GmailProfile { try await base.profile() }
    func labels() async throws -> [GmailLabel] { [] }
    func labels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>] { [:] }
    func listMessages(query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) throws -> MessageListPage {
        listTokens.append(pageToken ?? "first")
        listQueries.append(query ?? "")
        listIncludesSpamTrash.append(includeSpamTrash)
        listLimits.append(maxResults)
        return try pages[pageToken ?? "first"] ?? decode(MessageListPage.self, "{}")
    }
    func messages(ids: [String], format: MessageFormat, metadataHeaders: [String]) async throws -> [String: Result<GmailMessage, GmailError>] {
        metadataRequests.append(ids)
        let result = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, metadataErrors[id].map { .failure($0) } ?? metadata[id].map { .success($0) } ?? Result<GmailMessage, GmailError>.failure(.notFound))
        })
        if holdsMetadata { holdsMetadata = false; await withCheckedContinuation { heldMetadata = $0 } }
        return result
    }
    func history(startHistoryID: String, pageToken: String?) throws -> HistoryPage {
        if expiresHistory { expiresHistory = false; throw GmailError.notFound }
        return try historyPages.isEmpty ? decode(HistoryPage.self, #"{"historyId":"\#(startHistoryID)"}"#) : historyPages.removeFirst()
    }
    func attachment(messageID: String, attachmentID: String) async -> Data {
        downloadRequests += 1
        if holdsDownload { holdsDownload = false; await withCheckedContinuation { heldDownload = $0 } }
        return Data("file".utf8)
    }
    func threads(ids: [String], format: MessageFormat, metadataHeaders: [String]) throws -> [String: Result<GmailThread, GmailError>] {
        try Dictionary(uniqueKeysWithValues: ids.map { id in
            let messages = metadata.values.filter { $0.threadId == id }
            guard !messages.isEmpty else { return (id, .failure(.notFound)) }
            // GmailMessage isn't Encodable, so construct the selected synthetic source again.
            let json = #"{"id":"\#(id)","messages":[\#(messages.map { #"{"id":"\#($0.id)","threadId":"\#(id)","historyId":"200","payload":{"headers":[]}}"# }.joined(separator: ","))]}"#
            return (id, .success(try decode(GmailThread.self, json)))
        })
    }
    func thread(id: String, format: MessageFormat) async throws -> GmailThread { try await base.thread(id: id, format: format) }
    func listThreads(query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadListPage { try await base.listThreads(query: query, labelIDs: labelIDs, includeSpamTrash: includeSpamTrash, pageToken: pageToken, maxResults: maxResults) }
    func modifyThreads(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws -> LabelChangeResult { try await base.modifyThreads(ids: ids, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs) }
    func trashThreads(ids: [String]) async throws -> LabelChangeResult { try await base.trashThreads(ids: ids) }
    func untrashThreads(ids: [String]) async throws -> LabelChangeResult { try await base.untrashThreads(ids: ids) }
    func batchModifyMessages(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws -> LabelChangeResult { try await base.batchModifyMessages(ids: ids, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs) }
    func createLabel(name: String, color: LabelColor?) async throws -> GmailLabel { try await base.createLabel(name: name, color: color) }
    func patchLabel(id: String, name: String?, color: LabelColorChange?) async throws -> GmailLabel { try await base.patchLabel(id: id, name: name, color: color) }
    func deleteLabel(id: String) async throws { try await base.deleteLabel(id: id) }
    func drafts(query: String?, pageToken: String?, maxResults: Int) async throws -> DraftListPage { try await base.drafts(query: query, pageToken: pageToken, maxResults: maxResults) }
    func draft(id: String, format: MessageFormat) async throws -> GmailDraft { try await base.draft(id: id, format: format) }
    func createDraft(_ message: OutgoingMessage) async throws -> GmailDraft { try await base.createDraft(message) }
    func updateDraft(id: String, with message: OutgoingMessage) async throws -> GmailDraft { try await base.updateDraft(id: id, with: message) }
    func sendDraft(id: String, with message: OutgoingMessage) async throws -> GmailMessage { try await base.sendDraft(id: id, with: message) }
    func deleteDraft(id: String) async throws { try await base.deleteDraft(id: id) }
}
