import AppKit
import GmailAPI
import MailStore
import Testing
@testable import Tern

@MainActor @Suite struct AttachmentLibraryActionTests {
    @Test func busyCommandsCannotReplaceAnOpenWithRetry() async throws {
        let mailbox = try mailbox()
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var attempts = 0
        let model = AttachmentLibraryModel(mailbox: mailbox, openWithFile: { _ in
            attempts += 1
            if attempts == 1 {
                for await _ in gate.stream { break }
                throw GmailError.unauthorized
            }
        })
        let item = file(account: "audit")
        let opening = Task { await model.openWith(item) }
        defer { opening.cancel() }
        try await waitUntil { attempts == 1 }
        #expect(model.isWorking)
        // Each command would fail for this nonexistent account if it were admitted.
        let unavailable = file(account: "missing")
        await model.preview(unavailable)
        await model.copyFile(unavailable)
        await model.openFile(unavailable)
        await model.retryIndexing()
        await model.retryLastAction()
        #expect(model.isWorking)
        #expect(model.errorMessage == nil)
        gate.continuation.yield()
        await opening.value
        #expect(!model.isWorking)
        #expect(model.errorMessage?.contains("Sign in") == true)
        await model.retryLastAction()
        #expect(attempts == 2)
        #expect(model.errorMessage == nil)
        #expect(model.previewURL == nil)
        await mailbox.stop()
    }

    @Test func previewRetryKeepsTheOriginalSelectionAfterItChanges() async throws {
        let mailbox = try mailbox()
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        let first = file(account: "audit")
        var second = first
        second.partID = "2"
        second.filename = "Second.txt"
        let files = [first.attachment, second.attachment]
        try await mailbox.cache.write { tx in
            let message = MessageRecord(accountID: "audit", id: "m3", threadID: "t2", historyID: 1,
                date: .now, snippet: "", sender: "Example", recipients: "", cc: nil, subject: "Plans", sizeEstimate: 100)
            try tx.replaceLibraryAttachments(files, message: message, labelIDs: [])
        }
        let model = AttachmentLibraryModel(mailbox: mailbox)
        let observing = Task { await model.reload() }
        defer { observing.cancel() }
        try await waitUntil { model.items.count == 2 }
        let focus = try #require(model.items.first)
        model.unavailableAccountIDs = ["audit"]
        model.selection = Set(model.items.map(\.id))
        await model.preview(focus)
        #expect(model.errorMessage != nil)
        model.unavailableAccountIDs = []
        #expect(model.selection.isEmpty)
        await model.retryLastAction()
        #expect(model.previewURLs.count == 2)
        #expect(model.previewURL?.lastPathComponent == focus.filename)
        #expect(model.errorMessage == nil)
        await mailbox.stop()
    }

    @Test func copyReportsPartialFailureAndRetryCopiesTheOriginalSelection() async throws {
        let mailbox = try mailbox()
        defer { try? FileManager.default.removeItem(at: mailbox.downloadsDirectory) }
        await mailbox.addAccount(AccountRecord(id: "second", email: "second@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now), gmail: AuditGmail())
        let pasteboard = NSPasteboard(name: .init("Tern.AttachmentTests.\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }
        let model = AttachmentLibraryModel(mailbox: mailbox, pasteboard: pasteboard)
        let selected = [file(account: "audit"), file(account: "second")]
        model.unavailableAccountIDs = ["second"]
        await model.copyFiles(selected)
        #expect(urls(in: pasteboard).count == 1)
        #expect(model.errorMessage?.contains("Copied 1 of 2 files") == true)

        model.unavailableAccountIDs = []
        model.selection = []
        await model.retryLastAction()
        let copied = urls(in: pasteboard)
        #expect(copied.count == 2)
        #expect(Set(copied).count == 2)
        #expect(copied.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(model.errorMessage == nil)
        #expect(!model.isWorking)
        await mailbox.stop()
    }

    private func mailbox() throws -> MailboxModel {
        MailboxModel(account: AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now), cache: try MailCache.inMemory(), gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory,
            downloadsDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    private func file(account: String) -> AttachmentLibraryItem {
        let attachment = AttachmentRecord(accountID: account, messageID: "m3", partID: "1", attachmentID: "a-m3",
            filename: "Trail map.txt", mimeType: "text/plain",
            size: Data("Synthetic attachment for the UI audit.\n".utf8).count, isInline: false)
        return AttachmentLibraryItem(attachment: attachment, threadID: "t2", sender: "Example", subject: "Plans", date: .now)
    }

    private func urls(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
