import AppKit
import Foundation
import MailStore
import MessageContent

/// Scripting reads immutable metadata snapshots; it never waits for SQLite or Google.
@MainActor
final class MailScriptingBridge {
    static let shared = MailScriptingBridge()

    private struct Selection: Equatable, Sendable {
        let conversations: Set<ThreadKey>
        let messages: Set<MailListRowID>
        let messageMode: Bool
    }

    private var mailboxProvider: @MainActor () -> MailboxModel?
    private weak var sourceMailbox: MailboxModel?
    private var selection: Selection?
    private var generation = 0
    private var refresh: Task<Void, Never>?
    private var firstSnapshot: Task<Void, Never>?
    private var conversations: [MailScriptConversation] = []
    private var messages: [MailScriptMessage] = []

    init(mailboxProvider: @escaping @MainActor () -> MailboxModel? = { nil }) {
        self.mailboxProvider = mailboxProvider
    }

    deinit { refresh?.cancel(); firstSnapshot?.cancel() }

    func bind(_ app: AppModel) {
        mailboxProvider = { [weak app] in
            guard let app, case .signedIn = app.phase else { return nil }
            return app.mailbox
        }
        refreshSelection(mailboxProvider())
    }

    func refreshSelection(_ mailbox: MailboxModel?) {
        generation += 1
        refresh?.cancel(); refresh = nil
        firstSnapshot?.cancel(); firstSnapshot = nil
        conversations = []; messages = []; selection = nil
        sourceMailbox = mailbox
        guard let mailbox, mailboxProvider() === mailbox else { return }
        let selected = Self.currentSelection(mailbox)
        selection = selected
        let current = generation
        let emailByAccount = Dictionary(uniqueKeysWithValues: mailbox.accounts.map { ($0.account.id, $0.account.email) })
        let cache = mailbox.cache
        let groups = Dictionary(grouping: selected.conversations, by: \.accountID).mapValues { $0.map(\.threadID) }
        let (ready, completion) = AsyncStream<Void>.makeStream()
        firstSnapshot = Task { for await _ in ready {} }
        refresh = Task { [weak self, weak mailbox] in
            defer { completion.finish() }
            do {
                for try await entries in cache.messageListEntries(threadsByAccount: groups) {
                    try Task.checkCancellation()
                    let records = try await cache.read { transaction in
                        var records: [MailScriptRecord] = []
                        for key in selected.conversations.sorted() {
                            guard let email = emailByAccount[key.accountID], let thread = try transaction.thread(id: key.threadID, accountID: key.accountID) else { continue }
                            let all = entries.filter { $0.message.accountID == key.accountID && $0.message.threadID == key.threadID }
                                .map(\.message).sorted { ($0.date, $0.id) < ($1.date, $1.id) }
                            let included = selected.messageMode ? all.filter { message in
                                selected.messages.contains(.init(accountID: key.accountID, threadID: key.threadID, messageID: message.id))
                            } : all
                            guard let last = included.last else { continue }
                            records.append(MailScriptRecord(accountID: key.accountID, threadID: key.threadID, messageID: nil,
                                subject: selected.messageMode ? last.subject : thread.subject, sender: last.sender,
                                date: selected.messageMode ? last.date : thread.lastDate, email: email))
                            for message in included {
                                records.append(MailScriptRecord(accountID: key.accountID, threadID: key.threadID, messageID: message.id,
                                    subject: message.subject, sender: message.sender, date: message.date, email: email))
                            }
                        }
                        return records
                    }
                    guard let self, let mailbox, !Task.isCancelled, self.isCurrent(current, mailbox: mailbox, selection: selected) else { return }
                    self.conversations = records.filter { $0.messageID == nil }.map { MailScriptConversation(record: $0, bridge: self, generation: current) }
                    self.messages = records.filter { $0.messageID != nil }.map { MailScriptMessage(record: $0, bridge: self, generation: current) }
                    completion.finish()
                }
            } catch {
                if let self, self.generation == current {
                    self.conversations = []; self.messages = []; self.selection = nil
                }
            }
        }
    }

    var selectedConversations: [MailScriptConversation] { hasCurrentSelection ? conversations : [] }
    var selectedMessages: [MailScriptMessage] { hasCurrentSelection ? messages : [] }

    func waitForRefresh() async { await firstSnapshot?.value }

    fileprivate func isValid(generation: Int, accountID: String) -> Bool {
        generation == self.generation && hasCurrentSelection && sourceMailbox?.account(id: accountID) != nil
    }

    fileprivate func messages(in record: MailScriptRecord, generation: Int) -> [MailScriptMessage] {
        guard isValid(generation: generation, accountID: record.accountID) else { return [] }
        return messages.filter { $0.accountID == record.accountID && $0.threadID == record.threadID }
    }

    private var hasCurrentSelection: Bool {
        guard let mailbox = sourceMailbox, let selection else { return false }
        return isCurrent(generation, mailbox: mailbox, selection: selection)
    }

    private func isCurrent(_ generation: Int, mailbox: MailboxModel, selection: Selection) -> Bool {
        generation == self.generation && sourceMailbox === mailbox && mailboxProvider() === mailbox
            && selection == Self.currentSelection(mailbox)
            && selection.conversations.allSatisfy { mailbox.account(id: $0.accountID) != nil }
    }

    private static func currentSelection(_ mailbox: MailboxModel) -> Selection {
        let messageMode = !mailbox.listPreferences.conversations
        let messages = messageMode ? mailbox.selectedMessageRows : []
        return Selection(conversations: messageMode ? Set(messages.map(\.threadKey)) : mailbox.selectedThreadIDs,
            messages: messages, messageMode: messageMode)
    }
}

fileprivate struct MailScriptRecord: Sendable {
    let accountID: String
    let threadID: String
    let messageID: String?
    let subject: String
    let sender: String
    let date: Date
    let email: String

    var identifier: String {
        func part(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        return (messageID == nil ? "c" : "m") + part(accountID) + part(threadID) + (messageID.map(part) ?? "")
    }
    var link: MailLink { .init(accountID: accountID, threadID: threadID, messageID: messageID) }
}

/// The dictionary exposes getters only. Disable KVC's fallback access to stored ivars.
@MainActor @objc(TernScriptMailObject)
class MailScriptObject: NSObject {
    fileprivate let record: MailScriptRecord
    private weak var bridge: MailScriptingBridge?
    fileprivate let generation: Int

    fileprivate init(record: MailScriptRecord, bridge: MailScriptingBridge, generation: Int) {
        self.record = record; self.bridge = bridge; self.generation = generation
    }
    override class var accessInstanceVariablesDirectly: Bool { false }
    fileprivate var isValid: Bool { bridge?.isValid(generation: generation, accountID: record.accountID) == true }
    @objc dynamic var scriptID: String { isValid ? record.identifier : "" }
    @objc dynamic var accountID: String { isValid ? record.accountID : "" }
    @objc dynamic var threadID: String { isValid ? record.threadID : "" }
    @objc dynamic var subject: String { isValid ? record.subject : "" }
    @objc dynamic var sender: String { isValid ? record.sender : "" }
    @objc dynamic var sentDate: Date? { isValid ? record.date : nil }
    @objc dynamic var ternLink: String { isValid ? record.link.ternURL?.absoluteString ?? "" : "" }
    @objc dynamic var gmailLink: String { isValid ? record.link.gmailURL(email: record.email)?.absoluteString ?? "" : "" }

    nonisolated fileprivate func specifier(collection: String) -> NSScriptObjectSpecifier? {
        // NSObject's scripting hook is nonisolated. Cocoa scripting normally
        // calls it on the UI thread; reject other callers before reading UI state.
        guard Thread.isMainThread else { return nil }
        let identifier = MainActor.assumeIsolated { isValid ? record.identifier : nil }
        // Only the Sendable identifier crosses the isolation boundary. The
        // Foundation specifier is created and returned within this callback.
        guard let identifier, let description = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: nil,
            key: collection, uniqueID: identifier)
    }

    fileprivate var owningBridge: MailScriptingBridge? { bridge }
}

@MainActor @objc(TernScriptConversation)
final class MailScriptConversation: MailScriptObject {
    @objc dynamic var selectedMessages: [MailScriptMessage] { owningBridge?.messages(in: record, generation: generation) ?? [] }
    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? { specifier(collection: "ternConversations") }
}

@MainActor @objc(TernScriptMessage)
final class MailScriptMessage: MailScriptObject {
    @objc dynamic var messageID: String { isValid ? record.messageID ?? "" : "" }
    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? { specifier(collection: "ternMessages") }
}

extension NSApplication {
    @objc var ternSelectedConversations: [MailScriptConversation] { MailScriptingBridge.shared.selectedConversations }
    @objc var ternSelectedMessages: [MailScriptMessage] { MailScriptingBridge.shared.selectedMessages }
    @objc var ternConversations: [MailScriptConversation] { ternSelectedConversations }
    @objc var ternMessages: [MailScriptMessage] { ternSelectedMessages }
    @objc(valueInTernConversationsWithUniqueID:)
    func ternConversation(uniqueID: String) -> MailScriptConversation? { ternConversations.first { $0.scriptID == uniqueID } }
    @objc(valueInTernMessagesWithUniqueID:)
    func ternMessage(uniqueID: String) -> MailScriptMessage? { ternMessages.first { $0.scriptID == uniqueID } }
}
