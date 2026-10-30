import AppKit
import Foundation
import MailStore
import MessageContent
import SyncEngine
import TernAI

struct AssistantSource: Identifiable, Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case mail(threadID: String, messageID: String?, partID: String?)
        case calendar(calendarID: String, eventID: String)
    }
    let accountID: String
    let target: Target
    let title: String

    init(accountID: String, threadID: String, messageID: String?, partID: String?, title: String) {
        self.accountID = accountID; self.title = title
        target = .mail(threadID: threadID, messageID: messageID, partID: partID)
    }

    init(accountID: String, calendarID: String, eventID: String, title: String) {
        self.accountID = accountID; self.title = title
        target = .calendar(calendarID: calendarID, eventID: eventID)
    }

    var threadID: String { if case .mail(let id, _, _) = target { id } else { "" } }
    var messageID: String? { if case .mail(_, let id, _) = target { id } else { nil } }
    var partID: String? { if case .mail(_, _, let id) = target { id } else { nil } }
    var isCalendar: Bool { if case .calendar = target { true } else { false } }
    var systemImage: String { isCalendar ? "calendar" : (partID == nil ? "envelope" : "paperclip") }

    var id: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let parts: [String]
        let prefix: String
        switch target {
        case .mail(let thread, let message, let part):
            parts = [accountID, thread, message ?? "", part ?? ""]; prefix = "tern:"
        case .calendar(let calendar, let event):
            parts = [accountID, calendar, event]; prefix = "tern-calendar:"
        }
        return prefix + parts.map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }.joined(separator: "/")
    }
}

struct AssistantToolResult: Sendable {
    let data: AIJSON
    let sources: [AssistantSource]
    let createdDraftID: String?
    let emailResults: [AssistantEmailResult]
    let calendarProposals: [AssistantCalendarProposal]
    let availabilityChoices: [AssistantAvailabilityChoice]
    let draftStyleNote: String?

    init(data: AIJSON, sources: [AssistantSource] = [], createdDraftID: String? = nil,
         emailResults: [AssistantEmailResult] = [], calendarProposals: [AssistantCalendarProposal] = [],
         availabilityChoices: [AssistantAvailabilityChoice] = [], draftStyleNote: String? = nil) {
        self.data = data
        self.sources = sources
        self.createdDraftID = createdDraftID
        self.emailResults = emailResults
        self.calendarProposals = calendarProposals
        self.availabilityChoices = availabilityChoices
        self.draftStyleNote = draftStyleNote
    }
}

/// Existing mail adapters retain their source-compatible spelling.
typealias MailAssistantToolResult = AssistantToolResult

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
    var writingStyleGate: (@MainActor (String, AssistantWritingStyleRound?) async throws -> AssistantDraftStyleDecision)?
    var writingStyleIsCurrent: (@MainActor (String, AssistantWritingStyleRound?, AssistantDraftStyleDecision) -> Bool)?
    private var emailSources: [String: String] = [:]
    private var retrievedEmails: [String: RegisteredEmail] = [:]

    private struct RegisteredEmail {
        let email: AssistantEmailResult
        weak var owner: AccountMailbox?
    }

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

        mutating func completed(_ call: AIToolCall, arguments: AIJSON) throws -> MailAssistantToolResult? {
            if let prior = calls[call.id] {
                guard prior.matches(call, arguments: arguments) else { throw ToolError.changedCall }
                return prior.result
            }
            if let prior = calls.values.first(where: { !$0.published && $0.result != nil && $0.matches(call, arguments: arguments) }) {
                guard calls.count < 50 else { throw ToolError.narrowScope }
                calls[call.id] = prior
                return prior.result
            }
            return nil
        }

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

    func execute(_ call: AIToolCall, writingStyleRound: AssistantWritingStyleRound? = nil) async throws -> MailAssistantToolResult {
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
        case "present_emails": result = try presentEmails(arguments)
        case "prepare_draft": result = try await prepareDraft(arguments, call: call, writingStyleRound: writingStyleRound)
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
                try found.compactMap { id -> (ThreadRecord, MessageRecord?)? in
                    guard let thread = try tx.thread(id: id, accountID: accountID) else { return nil }
                    let messages = try tx.messages(threadID: id, accountID: accountID)
                    return (thread, messages.last(where: { $0.date == thread.lastDate }) ?? messages.last)
                }
            }
            try checkOwner(owner)
            var labelIterator = mailbox.cache.threadLabels(threadsByAccount: [accountID: found]).makeAsyncIterator()
            let labels = try await labelIterator.next() ?? []
            try checkOwner(owner)
            let labelsByThread = Dictionary(uniqueKeysWithValues: labels.map { ($0.threadID, $0.labels) })
            let rows = try records.map { record, message -> AIJSON in
                let source = AssistantSource(accountID: accountID, threadID: record.id, messageID: nil, partID: nil, title: record.subject)
                sources.append(source)
                let email = emailResult(source: source, sender: message?.sender ?? record.participants,
                                        subject: record.subject, snippet: record.snippet, date: record.lastDate,
                                        isUnread: record.isUnread, isStarred: record.isStarred,
                                        messageCount: record.messageCount, labels: labelsByThread[record.id] ?? [], owner: owner)
                try register(email, sources: [source], owner: owner)
                return .object([
                    "account_id": .string(accountID), "thread_id": .string(record.id),
                    "subject": .string(record.subject), "snippet": .string(record.snippet),
                    "sender": .string(message?.sender ?? record.participants), "date": try json(record.lastDate),
                    "is_unread": .bool(record.isUnread), "is_starred": .bool(record.isStarred),
                    "message_count": .number(Double(record.messageCount)),
                    "labels": .array(email.labels.map { .string($0.name) }),
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
        guard let mailbox = mailbox() else { throw AssistantMailError.accessChanged }
        var labelIterator = mailbox.cache.labels(accountID: accountID).makeAsyncIterator()
        let labels = try await labelIterator.next() ?? []
        try checkOwner(owner)
        if let latest = thread.messages.last, let source = sources.last {
            let email = emailResult(source: source, sender: latest.sender, subject: latest.subject,
                                    snippet: thread.snippet, date: latest.date,
                                    isUnread: thread.labelIDs.contains(SystemLabel.unread),
                                    isStarred: thread.labelIDs.contains(SystemLabel.starred),
                                    messageCount: thread.totalMessages,
                                    labels: labels.filter { !$0.isSystem && thread.labelIDs.contains($0.id) }, owner: owner)
            try register(email, sources: sources, owner: owner)
        }
        var value = try json(thread).objectValue ?? [:]
        value["sources"] = .array(sources.map(sourceJSON))
        return .init(data: .object(value), sources: sources)
    }

    private func emailResult(source: AssistantSource, sender: String, subject: String, snippet: String,
                             date: Date?, isUnread: Bool, isStarred: Bool, messageCount: Int,
                             labels: [LabelRecord], owner: AccountMailbox) -> AssistantEmailResult {
        let address = EmailAddress.parseList(sender).first
        let senderEmail = address?.address ?? ""
        let senderName = address?.name ?? (senderEmail.isEmpty ? sender : senderEmail)
        // Only an already-loaded, authenticated account photo may represent its
        // matching sender. Arbitrary senders retain the UI's initials fallback.
        let photo = senderEmail.caseInsensitiveCompare(owner.account.email) == .orderedSame
            ? AccountProfileImages.shared.image(for: owner.account.id)?.tiffRepresentation : nil
        return AssistantEmailResult(
            source: source, senderName: String(senderName.prefix(512)), senderEmail: String(senderEmail.prefix(512)),
            subject: String(subject.prefix(1_000)), snippet: String(snippet.prefix(1_000)), date: date,
            isUnread: isUnread, isStarred: isStarred, messageCount: messageCount,
            accountEmail: owner.account.email, labels: labels,
            avatarData: photo.flatMap { $0.count <= 256_000 ? $0 : nil }
        )
    }

    private func register(_ email: AssistantEmailResult, sources: [AssistantSource], owner: AccountMailbox) throws {
        try checkOwner(owner)
        try checkThread(accountID: email.source.accountID, threadID: email.source.threadID)
        let newIDs = Set(sources.map(\.id)).subtracting(emailSources.keys)
        guard emailSources.count + newIDs.count <= 1_000 else { throw ToolError.narrowScope }
        retrievedEmails[email.id] = RegisteredEmail(email: email, owner: owner)
        for source in sources { emailSources[source.id] = email.id }
    }

    private func presentEmails(_ args: [String: AIJSON]) throws -> MailAssistantToolResult {
        guard let requests = args["emails"]?.arrayValue, !requests.isEmpty, requests.count <= 12 else {
            throw ToolError.invalidArguments
        }
        var seen = Set<String>()
        var emails: [AssistantEmailResult] = []
        for request in requests {
            guard let fields = request.objectValue, Set(fields.keys) == ["source_id", "reason"] else {
                throw ToolError.invalidArguments
            }
            let sourceID = try string(fields, "source_id", limit: 2_048)
            let reason = try optionalString(fields, "reason", limit: 280)
            guard let id = emailSources[sourceID], let registered = retrievedEmails[id] else {
                throw AssistantMailError.invalidTarget
            }
            let source = registered.email.source
            let owner = try owner(source.accountID)
            guard registered.owner === owner else { throw AssistantMailError.accessChanged }
            try checkThread(accountID: source.accountID, threadID: source.threadID)
            guard seen.insert(id).inserted else { continue }
            var email = registered.email
            email.reason = reason
            emails.append(email)
        }
        try checkScope()
        return .init(data: .object([
            "status": .string("The selected conversations are displayed as email cards in the requested order. Do not repeat their metadata as a text list."),
            "presented_source_ids": .array(emails.map { .string($0.source.id) }),
            "count": .number(Double(emails.count))
        ]), sources: emails.map(\.source), emailResults: emails)
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

    private func prepareDraft(_ args: [String: AIJSON], call: AIToolCall,
                              writingStyleRound: AssistantWritingStyleRound?) async throws -> MailAssistantToolResult {
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
        if let completed = try draftCalls.completed(call, arguments: .object(args)) { return completed }
        let styleDecision = try await writingStyleGate?(accountID, writingStyleRound)
        try checkOwner(owner)
        if let styleDecision, !styleDecision.mayCreateDraft {
            return .init(data: .object([
                "status": .string("draft_not_created"), "style_applied": .bool(false),
                "style_status": .string(styleDecision.status), "note": .string(styleDecision.note),
            ]))
        }
        let reserved = try draftCalls.reserve(call, arguments: .object(args))
        if let result = reserved.result { return result }
        let draft = try await owner.engine.assistantPrepareDraft(
            id: reserved.draftID, replyKind: kind, messageID: messageID, expectedThreadID: threadID,
            recipients: recipients, subject: subject, text: body,
            isAuthorized: { [weak self, weak owner] in
                await MainActor.run {
                    guard let self, let owner else { return false }
                    guard (try? self.checkOwner(owner)) != nil else { return false }
                    if let styleDecision {
                        return self.writingStyleIsCurrent?(accountID, writingStyleRound, styleDecision) ?? true
                    }
                    return true
                }
            }
        )
        var data: [String: AIJSON] = [
            "draft_id": .string(draft.id), "account_id": .string(accountID),
            "status": .string("Editable draft created; Gmail draft save queued. Nothing was sent."),
            "subject": .string(draft.subject), "to": .array(draft.to.map { .string($0.address) })
        ]
        if let styleDecision {
            data["style_applied"] = .bool(styleDecision.styleApplied)
            data["style_status"] = .string(styleDecision.status)
            data["style_note"] = .string(styleDecision.note)
        }
        let result = MailAssistantToolResult(data: .object(data), createdDraftID: draft.id,
            draftStyleNote: styleDecision.flatMap { $0.styleApplied ? nil : $0.note })
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
            .init(name: "present_emails", description: "Show selected retrieved conversations as rich email cards. Use after search_mail or read_thread when the user asks to see, find, rank, or review emails. Choose only relevant results and order them by importance to the request; do not display every search hit automatically. Supply a short reason or null. Tern supplies the sender, subject, dates, labels, and avatar from trusted mail data. Do not repeat the cards as a plain-text list.", parameters: schema([
                "emails": .object([
                    "type": .string("array"), "minItems": .number(1), "maxItems": .number(12),
                    "description": .string("Up to twelve retrieved conversations in the desired display order. Duplicate conversations appear once."),
                    "items": schema([
                        "source_id": field("An exact source ID returned by search_mail or read_thread in this chat."),
                        "reason": field("Why this conversation matters to the request, at most 280 characters; null if unnecessary.", nullable: true)
                    ])
                ])
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
