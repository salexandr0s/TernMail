import Foundation
import MailStore
import MessageContent
import SyncEngine
import TernAI

struct AssistantSource: Identifiable, Hashable, Sendable {
    let accountID: String
    let threadID: String
    let messageID: String?
    let partID: String?
    let title: String

    var id: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "tern:" + [accountID, threadID, messageID ?? "", partID ?? ""].map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }.joined(separator: "/")
    }
}

struct MailAssistantToolResult: Sendable {
    let data: AIJSON
    let sources: [AssistantSource]
    let createdDraftID: String?

    init(data: AIJSON, sources: [AssistantSource] = [], createdDraftID: String? = nil) {
        self.data = data
        self.sources = sources
        self.createdDraftID = createdDraftID
    }
}

/// Each instance belongs to one immutable conversation scope. Tool arguments are
/// untrusted; account and message ownership come from Tern and Gmail.
@MainActor
final class MailAssistantTools {
    private let mailbox: () -> MailboxModel?
    private let accountAvailable: (String) -> Bool
    private let allowedAccountIDs: Set<String>
    private let allowedThreadIDs: Set<ThreadKey>?
    private let isScopeValid: @MainActor () -> Bool
    private var draftCalls = DraftCalls()

    /// Aliases share a reservation so recovering an interrupted call also resolves
    /// its earlier IDs. Published requests never absorb a later distinct request.
    struct DraftCalls {
        final class Reservation {
            let namespace: String
            let name: String
            let arguments: AIJSON
            let draftID = UUID().uuidString
            var result: MailAssistantToolResult?
            var published = false

            init(call: AIToolCall, arguments: AIJSON) {
                namespace = call.namespace
                name = call.name
                self.arguments = arguments
            }

            func matches(_ call: AIToolCall, arguments: AIJSON) -> Bool {
                namespace == call.namespace && name == call.name && self.arguments == arguments
            }
        }

        private var calls: [String: Reservation] = [:]

        mutating func reserve(_ call: AIToolCall, arguments: AIJSON) throws -> Reservation {
            if let prior = calls[call.id] {
                guard prior.matches(call, arguments: arguments) else { throw ToolError.changedCall }
                return prior
            }
            guard calls.count < 50 else { throw ToolError.narrowScope }
            let reservation = calls.values.first { !$0.published && $0.matches(call, arguments: arguments) }
                ?? Reservation(call: call, arguments: arguments)
            calls[call.id] = reservation
            return reservation
        }

        func markPublished(_ callID: String) {
            guard let reservation = calls[callID], reservation.result != nil else { return }
            reservation.published = true
        }
    }

    init(app: AppModel, allowedAccountIDs: Set<String>, allowedThreadIDs: Set<ThreadKey>? = nil,
         isScopeValid: @escaping @MainActor () -> Bool) {
        mailbox = { [weak app] in app?.mailbox }
        accountAvailable = { [weak app] id in app != nil && app?.accountsNeedingSignIn.contains(id) == false }
        self.allowedAccountIDs = allowedAccountIDs
        self.allowedThreadIDs = allowedThreadIDs
        self.isScopeValid = isScopeValid
    }

    /// Synthetic mailboxes exercise tool behavior without OAuth or a provider.
    init(mailbox: MailboxModel, allowedAccountIDs: Set<String>, allowedThreadIDs: Set<ThreadKey>? = nil,
         isScopeValid: @escaping @MainActor () -> Bool) {
        self.mailbox = { [weak mailbox] in mailbox }
        accountAvailable = { _ in true }
        self.allowedAccountIDs = allowedAccountIDs
        self.allowedThreadIDs = allowedThreadIDs
        self.isScopeValid = isScopeValid
    }

    func execute(_ call: AIToolCall) async throws -> MailAssistantToolResult {
        try checkScope()
        guard call.namespace == "tern", !call.id.isEmpty, call.arguments.utf8.count <= 150_000,
              let definition = Self.definitions.first(where: { $0.name == call.name }),
              let arguments = try AIJSON.decode(Data(call.arguments.utf8)).objectValue,
              Set(arguments.keys) == Set(definition.parameters["properties"]?.objectValue?.keys.map { $0 } ?? [])
        else { throw ToolError.invalidArguments }
        let result: MailAssistantToolResult
        switch call.name {
        case "search_mail": result = try await search(arguments)
        case "read_thread": result = try await readThread(arguments)
        case "read_attachment": result = try await readAttachment(arguments)
        case "prepare_draft": result = try await prepareDraft(arguments, call: call)
        default: throw ToolError.invalidArguments
        }
        try checkScope()
        return result
    }

    /// The coordinator calls this only after accepting and checkpointing the
    /// result. A cancelled caller leaves the draft recoverable under a new ID.
    func acknowledge(callID: String) {
        draftCalls.markPublished(callID)
    }

    private func search(_ args: [String: AIJSON]) async throws -> MailAssistantToolResult {
        let query = try string(args, "query", limit: 2_048)
        let selectedAccount = try optionalString(args, "account_id")
        let token = try optionalString(args, "page_token", limit: 4_096)
        guard token == nil || selectedAccount != nil else { throw ToolError.invalidArguments }
        let accounts = selectedAccount.map { [$0] } ?? allowedAccountIDs.sorted()
        guard accounts.count <= 10 else { throw ToolError.narrowScope }
        var pages: [AIJSON] = []
        var sources: [AssistantSource] = []
        for accountID in accounts {
            let owner = try owner(accountID)
            let page = try await owner.engine.searchGmail(SearchQuery(query), timeZone: .current, pageToken: token)
            try checkOwner(owner)
            let found = page.threadIDs.filter { isAllowedThread(accountID: accountID, threadID: $0) }
            guard let mailbox = mailbox() else { throw AssistantMailError.accessChanged }
            let records = try await mailbox.cache.read { tx in
                try found.compactMap { try tx.thread(id: $0, accountID: accountID) }
            }
            try checkOwner(owner)
            let rows = records.map { record -> AIJSON in
                let source = AssistantSource(accountID: accountID, threadID: record.id, messageID: nil, partID: nil, title: record.subject)
                sources.append(source)
                return .object([
                    "account_id": .string(accountID), "thread_id": .string(record.id),
                    "subject": .string(record.subject), "snippet": .string(record.snippet),
                    "source_id": .string(source.id)
                ])
            }
            pages.append(.object([
                "account_id": .string(accountID), "threads": .array(rows),
                "next_page_token": page.nextPageToken.map(AIJSON.string) ?? .null,
                "scope_filtered": .bool(found.count != page.threadIDs.count),
                "has_more": .bool(page.nextPageToken != nil)
            ]))
        }
        return .init(data: .object(["pages": .array(pages), "coverage": .string("One search page per requested account; not an exhaustive mailbox read.")]), sources: sources)
    }

    private func readThread(_ args: [String: AIJSON]) async throws -> MailAssistantToolResult {
        let accountID = try string(args, "account_id")
        let threadID = try string(args, "thread_id")
        let owner = try owner(accountID)
        try checkThread(accountID: accountID, threadID: threadID)
        let thread = try await owner.engine.assistantReadThread(threadID)
        try checkOwner(owner)
        let sources = thread.messages.map {
            AssistantSource(accountID: accountID, threadID: threadID, messageID: $0.messageID, partID: nil, title: $0.subject)
        }
        var value = try json(thread).objectValue ?? [:]
        value["sources"] = .array(sources.map(sourceJSON))
        return .init(data: .object(value), sources: sources)
    }

    private func readAttachment(_ args: [String: AIJSON]) async throws -> MailAssistantToolResult {
        let accountID = try string(args, "account_id")
        let messageID = try string(args, "message_id")
        let partID = try string(args, "part_id", allowsEmpty: true)
        let owner = try owner(accountID)
        // In a selected-thread scope, prove membership before downloading file bytes.
        let expected = try await selectedThread(containing: messageID, owner: owner)
        let attachment = try await owner.engine.assistantReadAttachment(messageID: messageID, partID: partID, expectedThreadID: expected)
        try checkOwner(owner)
        try checkThread(accountID: accountID, threadID: attachment.threadID)
        let extraction = Task.detached(priority: .userInitiated) {
            try AttachmentTextReader.extract(attachment.data, mimeType: attachment.mimeType, filename: attachment.filename)
        }
        let extracted = try await withTaskCancellationHandler {
            try await extraction.value
        } onCancel: {
            extraction.cancel()
        }
        try checkOwner(owner)
        let source = AssistantSource(accountID: accountID, threadID: attachment.threadID, messageID: messageID, partID: partID, title: attachment.filename)
        return .init(data: .object([
            "filename": .string(attachment.filename), "mime_type": .string(attachment.mimeType),
            "text": .string(extracted.text), "pages": try json(extracted.pages),
            "truncated": .bool(extracted.truncated), "limitations": .array(extracted.limitations.map(AIJSON.string)),
            "source": sourceJSON(source)
        ]), sources: [source])
    }

    private func prepareDraft(_ args: [String: AIJSON], call: AIToolCall) async throws -> MailAssistantToolResult {
        let accountID = try string(args, "account_id")
        let mode = try string(args, "reply_mode")
        let threadID = try optionalString(args, "thread_id")
        let messageID = try optionalString(args, "message_id")
        let subject = try string(args, "subject", limit: 998, allowsEmpty: true)
        let body = try string(args, "body", limit: 60_000)
        guard let recipientValues = args["to"]?.arrayValue, recipientValues.count <= 50,
              recipientValues.allSatisfy({ $0.stringValue != nil }) else { throw ToolError.invalidArguments }
        let recipients = recipientValues.compactMap(\.stringValue).map { EmailAddress(address: $0) }
        let owner = try owner(accountID)
        let kind: ReplyKind?
        switch mode {
        case "new":
            guard allowedThreadIDs == nil, threadID == nil, messageID == nil,
                  !recipients.isEmpty, recipients.allSatisfy(\.isValid) else { throw ToolError.invalidArguments }
            kind = nil
        case "reply", "reply_all":
            guard let threadID, let messageID, recipients.isEmpty else { throw ToolError.invalidArguments }
            try checkThread(accountID: accountID, threadID: threadID)
            // The engine checks that the actual message belongs to this thread.
            guard !messageID.isEmpty else { throw ToolError.invalidArguments }
            kind = mode == "reply" ? .reply : .replyAll
        default: throw ToolError.invalidArguments
        }
        let reserved = try draftCalls.reserve(call, arguments: .object(args))
        if let result = reserved.result { return result }
        let draft = try await owner.engine.assistantPrepareDraft(
            id: reserved.draftID, replyKind: kind, messageID: messageID, expectedThreadID: threadID,
            recipients: recipients, subject: subject, text: body,
            isAuthorized: { [weak self, weak owner] in
                await MainActor.run {
                    guard let self, let owner else { return false }
                    return (try? self.checkOwner(owner)) != nil
                }
            }
        )
        let result = MailAssistantToolResult(data: .object([
            "draft_id": .string(draft.id), "account_id": .string(accountID),
            "status": .string("Editable draft created; Gmail draft save queued. Nothing was sent."),
            "subject": .string(draft.subject), "to": .array(draft.to.map { .string($0.address) })
        ]), createdDraftID: draft.id)
        // The cache transaction has committed. Preserve its outcome even if scope
        // revocation or cancellation prevents this call from publishing it.
        reserved.result = result
        try checkOwner(owner)
        return result
    }

    private func selectedThread(containing messageID: String, owner: AccountMailbox) async throws -> String? {
        guard let allowedThreadIDs else { return nil }
        let keys = allowedThreadIDs.filter { $0.accountID == owner.account.id }
        guard keys.count <= 10 else { throw ToolError.narrowScope }
        for key in keys {
            let thread = try await owner.engine.assistantReadThread(key.threadID)
            try checkOwner(owner)
            if thread.messages.contains(where: { $0.messageID == messageID }) { return key.threadID }
        }
        throw AssistantMailError.invalidTarget
    }

    private func owner(_ id: String) throws -> AccountMailbox {
        try checkScope()
        guard allowedAccountIDs.contains(id), accountAvailable(id), let owner = mailbox()?.account(id: id) else {
            throw AssistantMailError.invalidTarget
        }
        return owner
    }

    private func checkOwner(_ expected: AccountMailbox) throws {
        guard try owner(expected.account.id) === expected else { throw AssistantMailError.accessChanged }
    }

    private func checkScope() throws {
        try Task.checkCancellation()
        guard isScopeValid(), mailbox() != nil else { throw AssistantMailError.accessChanged }
    }

    private func isAllowedThread(accountID: String, threadID: String) -> Bool {
        allowedThreadIDs?.contains(ThreadKey(accountID: accountID, threadID: threadID)) ?? true
    }

    private func checkThread(accountID: String, threadID: String) throws {
        guard isAllowedThread(accountID: accountID, threadID: threadID) else { throw AssistantMailError.invalidTarget }
    }

    private func string(_ args: [String: AIJSON], _ key: String, limit: Int = 512, allowsEmpty: Bool = false) throws -> String {
        guard let value = args[key]?.stringValue, value.count <= limit,
              allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalidArguments }
        return value
    }

    private func optionalString(_ args: [String: AIJSON], _ key: String, limit: Int = 512) throws -> String? {
        if args[key] == .null { return nil }
        return try string(args, key, limit: limit)
    }

    private func json<Value: Encodable>(_ value: Value) throws -> AIJSON {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try AIJSON.decode(encoder.encode(value))
    }

    private func sourceJSON(_ source: AssistantSource) -> AIJSON {
        .object(["source_id": .string(source.id), "account_id": .string(source.accountID),
                 "thread_id": .string(source.threadID), "message_id": source.messageID.map(AIJSON.string) ?? .null,
                 "part_id": source.partID.map(AIJSON.string) ?? .null, "title": .string(source.title)])
    }

    enum ToolError: Error, LocalizedError {
        case invalidArguments, changedCall, narrowScope
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "This mail request has missing or invalid fields."
            case .changedCall: "A draft request reused an existing action ID with different contents."
            case .narrowScope: "This request is too broad. Choose fewer accounts or start a new chat."
            }
        }
    }

    static var definitions: [AIToolDefinition] {
        func field(_ description: String, nullable: Bool = false) -> AIJSON {
            .object(["type": nullable ? .array([.string("string"), .string("null")]) : .string("string"), "description": .string(description)])
        }
        func schema(_ properties: [String: AIJSON]) -> AIJSON {
            .object(["type": .string("object"), "properties": .object(properties),
                     "required": .array(properties.keys.sorted().map(AIJSON.string)), "additionalProperties": .bool(false)])
        }
        return [
            .init(name: "search_mail", description: "Search mail using Gmail query syntax. Returns one bounded page per account and source IDs. Not an exhaustive scan.", parameters: schema([
                "query": field("Gmail search query, such as from:person@example.com or newer_than:7d."),
                "account_id": field("Account ID; null searches permitted accounts.", nullable: true),
                "page_token": field("Next-page token from a prior result; requires account_id. Otherwise null.", nullable: true)
            ])),
            .init(name: "read_thread", description: "Read a thread without marking it read. Returns source IDs and explicit truncation or missing-content limits.", parameters: schema([
                "account_id": field("Account ID from the current scope."), "thread_id": field("Thread ID from a source or selected context.")
            ])),
            .init(name: "read_attachment", description: "Read text or a PDF attachment by its source IDs. Reports unsupported or truncated content; never takes a file path.", parameters: schema([
                "account_id": field("Account ID."), "message_id": field("Message ID from read_thread."), "part_id": field("Attachment part ID from read_thread.")
            ])),
            .init(name: "prepare_draft", description: "Prepare an editable draft only when the user asks. Never sends. For replies, use source IDs and an empty to list; Tern retains recipients, subject, and threading.", parameters: schema([
                "account_id": field("Account ID."), "thread_id": field("Required for replies; null for new mail.", nullable: true),
                "message_id": field("Reply source message; null for new mail.", nullable: true),
                "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Email addresses for new mail; empty for replies.")]),
                "subject": field("Subject for new mail; ignored for replies, which retain the original subject."), "body": field("Plain-text draft body."),
                "reply_mode": .object(["type": .string("string"), "enum": .array(["new", "reply", "reply_all"].map(AIJSON.string))])
            ]))
        ]
    }
}
