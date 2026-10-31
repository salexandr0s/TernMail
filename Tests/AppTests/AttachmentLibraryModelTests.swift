import Foundation
import MailStore
import Observation
import Testing
@testable import Tern

@MainActor @Suite struct AttachmentLibraryModelTests {
    @Test func pagesPastFiveHundredAndFilterChangesResetPage() async throws {
        let mailbox = try mailbox()
        try await mailbox.cache.write { tx in
            for index in 0..<605 {
                let record = MessageRecord(accountID: "audit", id: "m\(index)", threadID: "t\(index)",
                    historyID: 1, date: Date(timeIntervalSince1970: Double(index)), snippet: "", sender: "Mira",
                    recipients: "", cc: nil, subject: "Invoice", sizeEstimate: 32)
                let file = AttachmentRecord(accountID: "audit", messageID: record.id, partID: "1", attachmentID: nil,
                    filename: "invoice-\(index).pdf", mimeType: "application/pdf", size: 32, isInline: false)
                try tx.replaceLibraryAttachments([file], message: record, labelIDs: [])
            }
        }
        let model = AttachmentLibraryModel(mailbox: mailbox)
        for page in 0..<7 {
            let observing = Task { await model.reload() }
            try await waitUntil { model.pageOffset == page * 100 && model.items.first?.messageID == "m\(604 - page * 100)" }
            #expect(model.items.count == (page == 6 ? 5 : 100))
            #expect(model.totalCount == 605)
            observing.cancel()
            await model.loadMore()
        }
        model.search = "invoice-604.pdf"
        let filtered = Task { await model.reload() }
        defer { filtered.cancel() }
        try await waitUntil { model.totalCount == 1 && model.pageOffset == 0 }
        #expect(!model.hasMore)
        await mailbox.stop()
    }

    @Test func calendarRangeIncludesTheWholeFinalDayAndClearRemovesEveryFilter() throws {
        let model = AttachmentLibraryModel(mailbox: try mailbox())
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        model.endDate = day
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))
        #expect(model.query.endDate == expected)
        model.startDate = day; model.accountID = "audit"; model.search = "invoice"
        model.sender = "Mira"; model.fileExtension = "pdf"; model.category = .invoice
        model.minimumSize = 2; model.maximumSize = 400; model.label = .init(accountID: "audit", id: "work")
        model.clearFilters()
        #expect(model.query == AttachmentLibraryQuery(accountIDs: ["audit"]))
    }

    @Test func returningKeepsMatchingResultsAndRefreshesChangesMadeWhileAway() async throws {
        let mailbox = try mailbox()
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        try await mailbox.cache.write { tx in
            for (account, id) in [("audit", "kept"), ("audit", "removed"), ("second", "other")] {
                let message = MessageRecord(accountID: account, id: id, threadID: id, historyID: 1,
                    date: .now, snippet: "", sender: "Example", recipients: "", cc: nil,
                    subject: "Documents", sizeEstimate: 32)
                let file = AttachmentRecord(accountID: account, messageID: id, partID: "1", attachmentID: nil,
                    filename: "\(id).pdf", mimeType: "application/pdf", size: 32, isInline: false)
                try tx.replaceLibraryAttachments([file], message: message, labelIDs: [])
            }
        }
        let model = AttachmentLibraryModel(mailbox: mailbox)
        model.accountID = "audit"
        let first = Task { await model.reload() }
        try await waitUntil { model.totalCount == 2 && !model.isLoading }
        first.cancel()
        await first.value
        let removed = try #require(model.items.first { $0.messageID == "removed" })
        model.selection = [removed.id]
        let cached = model.items
        try await mailbox.cache.write { try $0.deleteLibraryAttachments(messageIDs: ["removed"], accountID: "audit") }
        #expect(model.items == cached)

        let changes = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = model.isLoading } onChange: { changes.continuation.yield() }
        let loadingChanges = Task {
            var count = 0
            for await _ in changes.stream { count += 1 }
            return count
        }
        let returning = Task { await model.reload() }
        try await waitUntil { model.totalCount == 1 }
        changes.continuation.finish()
        #expect(await loadingChanges.value == 0)
        #expect(model.selection.isEmpty)
        #expect(model.items.map(\.messageID) == ["kept"])
        returning.cancel()
        await returning.value

        model.accountID = "second"
        #expect(model.items.isEmpty)
        #expect(model.totalCount == 0)
        let otherAccount = Task { await model.reload() }
        try await waitUntil { model.items.map(\.messageID) == ["other"] }
        otherAccount.cancel()
        await otherAccount.value
        await mailbox.removeAccount(id: "second")
        #expect(model.items.isEmpty)
        #expect(model.totalCount == 0)
        model.accountID = ""
        let remainingAccount = Task { await model.reload() }
        defer { remainingAccount.cancel() }
        try await waitUntil { model.items.map(\.messageID) == ["kept"] }
        await mailbox.stop()
    }

    @Test func detectedCategoriesReachFiltersAndManualCorrectionSurvivesRefresh() async throws {
        let mailbox = try mailbox()
        let message = MessageRecord(accountID: "audit", id: "categorized", threadID: "categorized",
            historyID: 1, date: .now, snippet: "", sender: "Example Travel",
            recipients: "", cc: nil, subject: "Your travel documents", sizeEstimate: 100)
        let files = ["Fahrkarte-4821.pdf", "Receipt-4821.pdf", "Rechnung-4821.pdf"].enumerated().map { index, name in
            AttachmentRecord(accountID: "audit", messageID: message.id, partID: String(index), attachmentID: nil,
                filename: name, mimeType: "application/pdf", size: 32, isInline: false)
        }
        try await mailbox.cache.write { try $0.replaceLibraryAttachments(files, message: message, labelIDs: []) }
        let model = AttachmentLibraryModel(mailbox: mailbox)
        for category in [AttachmentCategory.ticket, .receipt, .invoice] {
            model.category = category
            let observing = Task { await model.reload() }
            try await waitUntil { model.items.count == 1 && model.items.first?.category == category }
            #expect(model.totalCount == 1)
            observing.cancel()
        }
        let invoice = try #require(model.items.first)
        await model.setCategory(.uncategorized, for: invoice)
        #expect(model.errorMessage == nil)
        try await mailbox.cache.write { try $0.replaceLibraryAttachments(files, message: message, labelIDs: ["updated"]) }
        model.category = .uncategorized
        let corrected = Task { await model.reload() }
        defer { corrected.cancel() }
        try await waitUntil { model.items.count == 1 && model.items.first?.category == .uncategorized }
        #expect(model.items.first?.id == invoice.id)
        await mailbox.stop()
    }

    @Test func sourceOpensOutsideCurrentMailboxAndRevokedAccessRejectsFiles() async throws {
        let mailbox = try mailbox()
        let model = AttachmentLibraryModel(mailbox: mailbox)
        let attachment = AttachmentRecord(accountID: "audit", messageID: "m4", partID: "1", attachmentID: nil,
            filename: "old-invoice.pdf", mimeType: "application/pdf", size: 20, isInline: false)
        let item = AttachmentLibraryItem(attachment: attachment, threadID: "t3", sender: "Mira", subject: "Old invoice", date: .distantPast)
        mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
        #expect(await model.openSource(item))
        #expect(model.sourceThreadKey == ThreadKey(accountID: "audit", threadID: "t3"))
        #expect(mailbox.selectedMailbox == .combined(AttachmentLibraryModel.mailboxID))
        #expect(try await mailbox.cache.read { try $0.thread(id: "t3", accountID: "audit") } != nil)
        model.unavailableAccountIDs = ["audit"]
        #expect(model.sourceThreadKey == nil)
        await model.preview(item)
        #expect(model.previewURL == nil)
        #expect(model.errorMessage?.contains("Sign in") == true)
        await mailbox.stop()
    }

    @Test func indexProgressEndsWhenIndexingCompletesFailsOrNeedsSignIn() async throws {
        let mailbox = try mailbox()
        let model = AttachmentLibraryModel(mailbox: mailbox)
        #expect(model.isBuildingIndex)
        var state = AttachmentIndexState(accountID: "audit")
        try await mailbox.cache.write { [state] tx in try tx.saveAttachmentIndexState(state) }
        let observing = Task { await model.start() }
        defer { observing.cancel() }
        try await waitUntil { model.indexStates.count == 1 }
        #expect(model.isBuildingIndex)
        model.unavailableAccountIDs = ["audit"]
        #expect(!model.isBuildingIndex)
        model.unavailableAccountIDs = []
        state.lastError = "Couldn't reach Gmail."
        try await mailbox.cache.write { [state] tx in try tx.saveAttachmentIndexState(state) }
        try await waitUntil { model.indexingNeedsRetry }
        #expect(!model.isBuildingIndex)
        state.lastError = nil
        state.isComplete = true
        try await mailbox.cache.write { [state] tx in try tx.saveAttachmentIndexState(state) }
        try await waitUntil { model.indexStates.first?.isComplete == true }
        #expect(!model.isBuildingIndex)
        await mailbox.stop()
    }

    @Test func fileExportPreservesDuplicatesAndExistingDestinationOnReadFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appending(path: "invoice.pdf")
        try Data("invoice".utf8).write(to: source)
        let first = try await AttachmentFileExport.copyWithoutReplacing(source, to: folder)
        let second = try await AttachmentFileExport.copyWithoutReplacing(source, to: folder)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
        do {
            try await AttachmentFileExport.save(root.appending(path: "missing"), to: first)
            Issue.record("A missing source must fail")
        } catch { #expect(try Data(contentsOf: first) == Data("invoice".utf8)) }
        #expect(AttachmentFileExport.safeFilename("../bad/name").contains("/") == false)
        #expect(AttachmentFileExport.safeFilename(String(repeating: "🦜", count: 200)).utf8.count <= 220)
    }

    private func mailbox() throws -> MailboxModel {
        MailboxModel(account: AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now), cache: try MailCache.inMemory(), gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory,
            downloadsDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Attachment observation did not reach its expected state")
                throw ObservationTimeout()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct ObservationTimeout: Error {}
}
