import Foundation
import MailStore
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import Tern

/// Evaluates the real toolbar declaration without creating or activating a
/// window. These dependency checks do not measure native controls or latency.
@Suite(.serialized) @MainActor struct MailToolbarObservationTests {
    @Test(arguments: [false, true])
    func selectionDoesNotInvalidateToolbarDeclaration(isCompact: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let mailbox = fixture.mailbox
        // Construct outside tracking: only evaluation of the actual body is
        // measured, including its nonescaping ToolbarItem content builders.
        let toolbar = MailToolbar(mailbox: mailbox, reply: { _, _ in }, isCompact: isCompact)
        let selections: [Set<ThreadKey>] = [[fixture.unread], [fixture.read], []]
        for selection in selections {
            // Observation callbacks are one-shot and fire before the write.
            // Re-arm for every synchronous transition, reading only afterwards.
            let count = invalidations(tracking: { _ = toolbar.body }) {
                mailbox.selectedThreadIDs = selection
            }
            #expect(count == 0,
                "Selection must update action content without invalidating the toolbar declaration")
        }
        let unrelatedCount = invalidations(tracking: { _ = toolbar.body }) {
            mailbox.notice = .init(message: "Synthetic unrelated notice")
        }
        #expect(unrelatedCount == 0)
        await mailbox.stop()
    }

    @Test
    func actionContentStillObservesSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let mailbox = fixture.mailbox
        let read = MailToolbarActions.Read(mailbox: mailbox)
        let trash = MailToolbarActions.Trash(mailbox: mailbox)
        let archive = MailToolbarActions.Archive(mailbox: mailbox)
        let reply = MailToolbarActions.Reply(mailbox: mailbox, kind: .reply,
            title: "Reply", symbol: "arrowshape.turn.up.left", reply: { _, _ in })
        let compactReplies = MailToolbarActions.CompactReplies(mailbox: mailbox, reply: { _, _ in })
        let controls: [(name: String, body: () -> Void)] = [
            ("Read", { _ = read.body }),
            ("Trash", { _ = trash.body }),
            ("Archive", { _ = archive.body }),
            ("Reply", { _ = reply.body }),
            ("Compact replies", { _ = compactReplies.body })
        ]
        let selections: [Set<ThreadKey>] = [[fixture.unread], [fixture.read], []]
        for control in controls {
            mailbox.selectedThreadIDs = []
            for selection in selections {
                let count = invalidations(tracking: control.body) {
                    mailbox.selectedThreadIDs = selection
                }
                #expect(count == 1, "\(control.name) must retain its own selection observation")
            }
            let unrelatedCount = invalidations(tracking: control.body) {
                mailbox.notice = .init(message: "Synthetic unrelated notice")
            }
            #expect(unrelatedCount == 0)
        }
        await mailbox.stop()
    }

    @Test
    func readStatePublicationUpdatesReadActionWithoutInvalidatingToolbar() async throws {
        let fixture = try await makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let mailbox = fixture.mailbox
        mailbox.selectedThreadIDs = [fixture.unread]
        let toolbar = MailToolbar(mailbox: mailbox, reply: { _, _ in })
        let read = MailToolbarActions.Read(mailbox: mailbox)
        let parentCallbacks = Mutex(0)
        let readCallbacks = Mutex(0)
        withObservationTracking { _ = toolbar.body } onChange: {
            parentCallbacks.withLock { $0 += 1 }
        }
        withObservationTracking { _ = read.body } onChange: {
            readCallbacks.withLock { $0 += 1 }
        }
        let initialRevision = mailbox.listPresentationRevision
        let accountID = fixture.unread.accountID
        do {
            try await mailbox.cache.write { tx in
                _ = try tx.applyLabelChange(messageID: "unread-message", added: [],
                    removed: [SystemLabel.unread], historyID: 2, accountID: accountID)
                try tx.rebuildThreads(["unread"], accountID: accountID)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while (mailbox.listPresentationRevision == initialRevision || !mailbox.allRead([fixture.unread])),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(mailbox.listPresentationRevision != initialRevision)
            #expect(mailbox.allRead([fixture.unread]))
            #expect(mailbox.selectedThreadIDs == [fixture.unread])
            #expect(readCallbacks.withLock { $0 } == 1)
            #expect(parentCallbacks.withLock { $0 } == 0)
        } catch {
            await mailbox.stop()
            throw error
        }
        await mailbox.stop()
    }

    private func invalidations(tracking read: () -> Void, mutate: () -> Void) -> Int {
        let callbacks = Mutex(0)
        withObservationTracking(read) {
            callbacks.withLock { $0 += 1 }
        }
        mutate()
        return callbacks.withLock { $0 }
    }

    private struct Fixture {
        let mailbox: MailboxModel
        let defaults: UserDefaults
        let suite: String
        let unread: ThreadKey
        let read: ThreadKey
    }

    private func makeFixture() async throws -> Fixture {
        let accountID = "toolbar-observation"
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            let unread = MessageRecord(accountID: accountID, id: "unread-message", threadID: "unread",
                historyID: 1, date: Date(timeIntervalSince1970: 2), snippet: "",
                sender: "sender@example.invalid", recipients: "reader@example.invalid", cc: nil,
                subject: "Synthetic unread conversation", sizeEstimate: 1)
            var read = unread
            read.id = "read-message"
            read.threadID = "read"
            read.subject = "Synthetic read conversation"
            read.date = Date(timeIntervalSince1970: 1)
            try tx.upsertMessages([
                .init(record: unread, labelIDs: [SystemLabel.inbox, SystemLabel.unread]),
                .init(record: read, labelIDs: [SystemLabel.inbox])
            ])
            try tx.rebuildThreads(["unread", "read"], accountID: accountID)
        }
        let suite = "MailToolbarObservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = MessageListPreferences(defaults: defaults)
        let account = AccountRecord(id: accountID, email: "reader@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory,
            syncEnabled: false, listPreferences: preferences)
        await mailbox.start()
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !mailbox.isListPresentationReady, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let unread = ThreadKey(accountID: accountID, threadID: "unread")
            let read = ThreadKey(accountID: accountID, threadID: "read")
            try #require(Set(mailbox.threads.map(\.key)) == [unread, read])
            try #require(!mailbox.allRead([unread]))
            try #require(mailbox.allRead([read]))
            try #require(mailbox.selectedThreadIDs.isEmpty)
            return Fixture(mailbox: mailbox, defaults: defaults, suite: suite, unread: unread, read: read)
        } catch {
            await mailbox.stop()
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
    }
}
