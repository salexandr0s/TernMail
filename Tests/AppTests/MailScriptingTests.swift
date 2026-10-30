import AppKit
import Foundation
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct MailScriptingTests {
    @Test func snapshotsExposeReadOnlyKVCMetadataWithAccountQualifiedIDsAndLinks() async throws {
        let fixture = try await Fixture()
        fixture.mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "t"), ThreadKey(accountID: "b", threadID: "t")]
        fixture.bridge.refreshSelection(fixture.mailbox)
        await fixture.bridge.waitForRefresh()
        let conversations = fixture.bridge.selectedConversations
        let messages = fixture.bridge.selectedMessages
        #expect(conversations.count == 2)
        #expect(messages.count == 3)
        #expect(Set(conversations.map(\.scriptID)).count == 2)
        #expect(Set(messages.map(\.scriptID)).count == 3)
        let first = try #require(messages.first { $0.accountID == "a" && $0.messageID == "m1" })
        #expect(first.value(forKey: "subject") as? String == "First A")
        #expect(first.value(forKey: "sender") as? String == "sender-a@example.invalid")
        #expect(first.value(forKey: "sentDate") as? Date == Date(timeIntervalSince1970: 100))
        let url = try #require(URL(string: first.ternLink))
        #expect(MailLink(url: url) == MailLink(accountID: "a", threadID: "t", messageID: "m1"))
        #expect(URLComponents(string: first.gmailLink)?.queryItems?.first(where: { $0.name == "authuser" })?.value == "a@example.invalid")
        #expect(!first.responds(to: NSSelectorFromString("setSubject:")))
        #expect(!MailScriptMessage.accessInstanceVariablesDirectly)
        let specifier = try #require(first.objectSpecifier as? NSUniqueIDSpecifier)
        #expect(specifier.uniqueID as? String == first.scriptID)
        #expect(specifier.key == "ternMessages")
        let rejectedOffMain = await Task.detached { first.objectSpecifier == nil }.value
        #expect(rejectedOffMain)
        #expect(NSApp.responds(to: NSSelectorFromString("ternSelectedMessages")))
        #expect(conversations.first { $0.accountID == "a" }?.selectedMessages.count == 2)
        try await fixture.mailbox.cache.write { transaction in
            if var message = try transaction.message(id: "m1", accountID: "a") {
                message.subject = "Updated A"; message.historyID += 1
                _ = try transaction.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox])])
                try transaction.rebuildThreads(["t"], accountID: "a")
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.bridge.selectedMessages.first(where: { $0.accountID == "a" && $0.messageID == "m1" })?.subject != "Updated A", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.bridge.selectedMessages.first(where: { $0.accountID == "a" && $0.messageID == "m1" })?.subject == "Updated A")
    }

    @Test func selectionChangesInvalidateRetainedObjectsBeforeAnyRefreshAndLateSnapshotsCannotReturn() async throws {
        let fixture = try await Fixture()
        fixture.mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "t")]
        fixture.bridge.refreshSelection(fixture.mailbox)
        await fixture.bridge.waitForRefresh()
        let retained = try #require(fixture.bridge.selectedMessages.first)
        fixture.mailbox.selectedThreadIDs = [ThreadKey(accountID: "b", threadID: "t")]
        #expect(fixture.bridge.selectedMessages.isEmpty)
        #expect(retained.subject.isEmpty)
        #expect(retained.sentDate == nil)
        #expect(retained.objectSpecifier == nil)
        fixture.bridge.refreshSelection(fixture.mailbox)
        fixture.mailbox.selectedThreadIDs = []
        await fixture.bridge.waitForRefresh()
        #expect(fixture.bridge.selectedConversations.isEmpty)
        #expect(fixture.bridge.selectedMessages.isEmpty)
    }

    @Test func messageModeDoesNotExposeUnselectedSiblingsAndRemovingTheMailboxInvalidatesRetainedMetadata() async throws {
        let fixture = try await Fixture()
        fixture.mailbox.listPreferences.conversations = false
        fixture.mailbox.selectedMessageRows = [.init(accountID: "a", threadID: "t", messageID: "m2")]
        fixture.bridge.refreshSelection(fixture.mailbox)
        await fixture.bridge.waitForRefresh()
        let retained = try #require(fixture.bridge.selectedMessages.first)
        #expect(fixture.bridge.selectedMessages.map(\.messageID) == ["m2"])
        #expect(fixture.bridge.selectedConversations.first?.selectedMessages.map(\.messageID) == ["m2"])
        await fixture.mailbox.removeAccount(id: "a")
        #expect(fixture.bridge.selectedMessages.isEmpty)
        #expect(retained.sender.isEmpty)
        fixture.context.mailbox = nil
        #expect(fixture.bridge.selectedMessages.isEmpty)
        #expect(retained.sender.isEmpty)
        #expect(retained.ternLink.isEmpty)
    }

    @Test func queuedDraftCopiesExcludedFromTheReaderAreAlsoExcludedFromScripting() async throws {
        let fixture = try await Fixture()
        try await fixture.mailbox.cache.write { transaction in
            if let message = try transaction.message(id: "m2", accountID: "a") {
                _ = try transaction.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox, SystemLabel.draft])])
                var draft = LocalDraft(accountID: "a", kind: .edit, content: DraftContent(subject: "Queued draft"),
                    rfcMessageID: "<queued-draft@example.invalid>", now: Date(timeIntervalSince1970: 200))
                draft.savedMessageID = "m2"; draft.threadID = "t"; draft.state = .sending
                try transaction.insertLocalDraft(draft)
                try transaction.rebuildThreads(["t"], accountID: "a")
            }
        }
        fixture.mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "t")]
        fixture.bridge.refreshSelection(fixture.mailbox)
        await fixture.bridge.waitForRefresh()
        #expect(fixture.bridge.selectedMessages.map(\.messageID) == ["m1"])
    }

    @Test func packagedDictionaryDeclaresOnlyReadAccessAndUsesRegisteredRuntimeClasses() throws {
        let url = try #require(Bundle.main.url(forResource: "Tern", withExtension: "sdef"))
        let dictionary = try XMLDocument(contentsOf: url)
        #expect(try dictionary.nodes(forXPath: "//command").isEmpty)
        let access = try dictionary.nodes(forXPath: "//property/@access | //element/@access").map(\.stringValue)
        #expect(!access.isEmpty && access.allSatisfy { $0 == "r" })
        #expect(NSClassFromString("TernScriptConversation") != nil)
        #expect(NSClassFromString("TernScriptMessage") != nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String == "Tern.sdef")
    }

    @MainActor private final class Context { var mailbox: MailboxModel? }

    @MainActor private struct Fixture {
        let mailbox: MailboxModel
        let context: Context
        let bridge: MailScriptingBridge

        init() async throws {
            let cache = try MailCache.inMemory()
            let preferences = MessageListPreferences(defaults: try #require(UserDefaults(suiteName: "MailScriptingTests-\(UUID().uuidString)")))
            preferences.conversations = true
            let first = AccountRecord(id: "a", email: "a@example.invalid", displayName: nil, grantedScopes: [], addedAt: .distantPast)
            mailbox = MailboxModel(account: first, cache: cache, gmail: AuditGmail(), outgoingDirectory: .temporaryDirectory,
                syncEnabled: false, listPreferences: preferences)
            let second = AccountRecord(id: "b", email: "b@example.invalid", displayName: nil, grantedScopes: [], addedAt: .distantPast)
            await mailbox.addAccount(second, gmail: AuditGmail(), syncEnabled: false)
            try await cache.write { transaction in
                for (accountID, messageID, subject, date) in [("a", "m1", "First A", 100.0), ("a", "m2", "Second A", 200), ("b", "m1", "Only B", 300)] {
                    let message = MessageRecord(accountID: accountID, id: messageID, threadID: "t", historyID: 1,
                        date: Date(timeIntervalSince1970: date), snippet: "", sender: "sender-\(accountID)@example.invalid",
                        recipients: "recipient@example.invalid", cc: nil, subject: subject, sizeEstimate: 10)
                    _ = try transaction.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox])])
                    try transaction.rebuildThreads(["t"], accountID: accountID)
                }
            }
            context = Context(); context.mailbox = mailbox
            let context = context
            bridge = MailScriptingBridge(mailboxProvider: { context.mailbox })
        }
    }
}
