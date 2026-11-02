import Foundation
import GmailAPI
import MailStore
import MessageContent
import os
import Testing
@testable import SyncEngine

@Suite struct ComposeRecoveryTests {
    @Test(.timeLimit(.minutes(1))) func stopWaitsForOutgoingCopyAndCleanup() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let draft = LocalDraft(accountID: account, kind: .new, content: DraftContent(),
            rfcMessageID: "<outgoing-stop@example.com>", now: baseDate)
        try await engine.createDraft(draft)
        let (entries, entered) = AsyncStream.makeStream(of: URL.self)
        let (releases, release) = AsyncStream.makeStream(of: Void.self)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let copying = Task {
            try await engine.attach(name: "held.txt", mimeType: "text/plain", to: draft.id) { url in
                entered.yield(url)
                var iterator = releases.makeAsyncIterator()
                _ = await iterator.next()
                return try await OutgoingAttachmentIO.shared.write(Data("held".utf8), to: url,
                    maximumBytes: 100, filename: "held.txt")
            }
        }
        var iterator = entries.makeAsyncIterator()
        let destination = try #require(await iterator.next())
        let stopping = Task {
            await engine.stop()
            finished.withLock { $0 = true }
        }
        do {
            try await waitForSyncCondition { await engine.isStopped }
            #expect(!finished.withLock { $0 })
            release.yield(())
            await #expect(throws: CancellationError.self) { try await copying.value }
            await stopping.value
        } catch {
            release.yield(())
            _ = try? await copying.value
            await stopping.value
            throw error
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await cache.read { try $0.outgoingAttachments(localDraftID: draft.id).isEmpty })
    }

    @Test func failedPreSendUploadRemainsCancellableButUncertainDeliveryDoesNot() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = LocalDraft(accountID: account, kind: .new,
            content: DraftContent(to: [.init(address: "pat@example.com")]),
            rfcMessageID: "<cancel-before-send@example.com>", now: baseDate)
        try await engine.createDraft(draft)
        await gmail.failNextDraftCall("create", with: .transport(.notConnectedToInternet))
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()
        let row = try #require(try await cache.read { try $0.composeRows(localDraftID: draft.id).first })
        let stored = try #require(try await cache.read { try $0.localDraft(id: draft.id) })
        #expect(row.attempts > 0 && !stored.sendRequested)
        #expect(stored.canCancelPendingExit(row))
        #expect(try await engine.undoSend(draft.id))
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.state } == .editing)

        try await engine.sendDraft(draft.id, delay: 0)
        await gmail.failNextDraftCall("send", with: .transport(.networkConnectionLost), afterApplying: true)
        await engine.sendDueDrafts()
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.sendRequested } == true)
        #expect(try await engine.undoSend(draft.id) == false)
    }

    @Test func aClaimedSendCannotBeCancelledUntilItIsRequeued() async throws {
        let (engine, cache, _, clock) = try await makeEngine()
        let draft = LocalDraft(accountID: account, kind: .new, content: DraftContent(),
            rfcMessageID: "<claimed-send@example.com>", now: baseDate)
        try await engine.createDraft(draft)
        try await engine.sendDraft(draft.id, delay: 0)
        try await cache.write { _ = try $0.claimDueActions(accountID: account, now: clock.now(), lane: .compose) }
        #expect(try await engine.undoSend(draft.id) == false)
        try await cache.write { try $0.requeueInterruptedActions(accountID: account) }
        #expect(try await engine.undoSend(draft.id))
    }

    @Test func deletedInlineImagesDoNotConsumeTheBudgetAndRemainAvailableForUndo() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let draft = LocalDraft(accountID: account, kind: .new, content: DraftContent(),
            rfcMessageID: "<inline-budget@example.com>", now: baseDate)
        try await engine.createDraft(draft)
        let bytes = Data(count: 14_000_000)
        let attached = try #require(try await engine.attachData(bytes, filename: "image.png", mimeType: "image/png", to: draft.id))
        let inline = try #require(try await engine.markInlineImage(attached))
        let cid = try #require(inline.contentID)
        var content = draft.content
        content.body.blocks = [.init(runs: [.init("", image: .init(contentID: cid))])]
        try await engine.updateDraft(draft.id, content: content)
        await #expect(throws: ComposeError.fileTooLarge("replacement.bin")) {
            try await engine.attachData(bytes, filename: "replacement.bin", mimeType: "application/octet-stream", to: draft.id)
        }
        content.body = ComposeDocument()
        try await engine.updateDraft(draft.id, content: content)
        #expect(try await engine.attachData(bytes, filename: "replacement.bin", mimeType: "application/octet-stream", to: draft.id) != nil)
        #expect(try await engine.outgoingAttachmentData(inline).count == bytes.count)
        #expect(try await cache.read { try $0.outgoingAttachments(localDraftID: draft.id).count } == 2)
    }

    @Test func oversizedFileIsRejectedBeforeCreatingItsDestination() async throws {
        let (engine, _, _, _) = try await makeEngine()
        let draft = LocalDraft(accountID: account, kind: .new, content: DraftContent(),
            rfcMessageID: "<large-file@example.com>", now: baseDate)
        try await engine.createDraft(draft)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 40_000_000)
        try handle.close()
        await #expect(throws: ComposeError.fileTooLarge(source.lastPathComponent)) {
            try await engine.attachFile(at: source, to: draft.id)
        }
        let folder = await engine.outgoingDirectory.appending(path: draft.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
