import Foundation
import MailStore
import MessageContent
import TernAI

/// One captured preparation owns read-only tools and fixed budgets. It never
/// changes the assistant's chat selection, source registry, drafts, or history.
@MainActor
final class MeetingPreparationService {
    static let candidateLimit = 20
    static let reportLimit = 5
    static let searchLimit = 2
    let access: MeetingPreparationAccess
    let isValid: @MainActor () -> Bool
    private let event: CalendarDisplayEvent
    private let tools: AssistantToolSession
    private let provider: any AIProvider
    private let loadSource: @MainActor (ThreadKey) async throws -> MeetingPreparationSourceSnapshot?
    private var candidates: [ThreadKey: MeetingPreparationCandidate] = [:]
    private var searches = 0
    private var reportAttempts = 0
    private var didDiscover = false

    init(event: CalendarDisplayEvent, access: MeetingPreparationAccess, tools: AssistantToolSession,
         provider: any AIProvider, loadSource: @escaping @MainActor (ThreadKey) async throws -> MeetingPreparationSourceSnapshot?,
         isValid: @escaping @MainActor () -> Bool) {
        self.event = event; self.access = access; self.tools = tools; self.provider = provider
        self.loadSource = loadSource; self.isValid = isValid
    }

    convenience init(event: CalendarDisplayEvent, access: MeetingPreparationAccess, tools: AssistantToolSession,
                     provider: any AIProvider, loadDetail: @escaping @MainActor (ThreadKey) async throws -> ThreadDetail?,
                     isValid: @escaping @MainActor () -> Bool) {
        self.init(event: event, access: access, tools: tools, provider: provider, loadSource: { key in
            guard let detail = try await loadDetail(key) else { return nil }
            return MeetingPreparationSourceSnapshot(detail: detail, revision: ThreadSummaryModel.revision(for: detail))
        }, isValid: isValid)
    }

    var providerUnavailableMessage: String? {
        if !access.scope.canUsePlan { return "Connect an assistant provider to generate meeting summaries. Source links are still available." }
        if !access.modelReady || access.modelID.isEmpty { return "Choose an available assistant model to generate meeting summaries. Source links are still available." }
        return nil
    }

    func discover(event: CalendarDisplayEvent, included: [MailLink], linked: [MailLink],
                  excluded: Set<ThreadKey>) async throws -> MeetingPreparationDiscovery {
        try validate()
        guard event == self.event, !didDiscover else { throw MeetingPreparationServiceError.eventChanged }
        didDiscover = true
        var ordered: [MeetingPreparationCandidate] = []
        var seen = Set<ThreadKey>()
        var omitted = 0
        var failures: [String] = []
        func append(_ source: MailLink, title: String, reason: MeetingPreparationCandidate.Reason) {
            let key = ThreadKey(accountID: source.accountID, threadID: source.threadID)
            guard !excluded.contains(key), seen.insert(key).inserted else { return }
            guard access.scope.accountIDs.contains(key.accountID) else {
                omitted += 1; return
            }
            guard ordered.count < Self.candidateLimit else { omitted += 1; return }
            ordered.append(MeetingPreparationCandidate(thread: key, title: title, reason: reason,
                source: MailLink(accountID: key.accountID, threadID: key.threadID, messageID: source.messageID)))
        }
        for source in included { append(source, title: "Included conversation", reason: .included) }
        for source in linked { append(source, title: "Event-linked conversation", reason: .eventLink) }
        let terms = MeetingPreparationMatching.terms(in: event)
        var more = false
        if !terms.isEmpty, ordered.count < Self.candidateLimit {
            let accounts = access.scope.accountIDs.sorted()
            // The existing search tool accepts up to ten accounts per request.
            // Larger profiles use two explicit accounts and disclose that gap.
            let targets: [String?] = accounts.count <= 10 ? [nil] : accounts.prefix(Self.searchLimit).map(Optional.some)
            more = accounts.count > 10
            let query = terms.prefix(2).map { "\"\($0)\"" }.joined(separator: " ") + " -in:trash -in:spam"
            for target in targets where searches < Self.searchLimit {
                try validate()
                searches += 1
                do {
                    let args: AIJSON = .object(["query": .string(query), "account_id": target.map(AIJSON.string) ?? .null,
                        "page_token": .null])
                    let result = try await tools.execute(AIToolCall(id: UUID().uuidString, namespace: "tern",
                        name: "search_mail", arguments: try args.jsonString()))
                    try validate()
                    let sources = Dictionary(result.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for page in result.data["pages"]?.arrayValue ?? [] {
                        more = more || page["has_more"]?.boolValue == true
                        for row in page["threads"]?.arrayValue ?? [] {
                            guard let account = row["account_id"]?.stringValue,
                                  page["account_id"]?.stringValue == account,
                                  let thread = row["thread_id"]?.stringValue,
                                  let id = row["source_id"]?.stringValue,
                                  let source = sources[id], !source.isCalendar,
                                  source.accountID == account, source.threadID == thread,
                                  access.scope.accountIDs.contains(account) else { throw MeetingPreparationServiceError.invalidSource }
                            let subject = row["subject"]?.stringValue ?? ""
                            let snippet = row["snippet"]?.stringValue ?? ""
                            guard MeetingPreparationMatching.matches(subject: subject, snippet: snippet, terms: terms) else { continue }
                            append(MailLink(accountID: account, threadID: thread), title: subject.isEmpty ? "Matching conversation" : subject,
                                reason: .titleMatch)
                        }
                    }
                } catch {
                    try validate()
                    failures.append("Some related mail could not be searched. Included and event-linked sources are still available.")
                }
            }
        } else if !terms.isEmpty { more = true }
        try validate()
        candidates = Dictionary(ordered.map { ($0.thread, $0) }, uniquingKeysWith: { first, _ in first })
        return MeetingPreparationDiscovery(candidates: ordered, omittedCount: omitted, hasMoreSearchResults: more,
            requiresManualSelection: terms.isEmpty, failures: Array(Set(failures)).sorted())
    }

    func summarize(_ candidate: MeetingPreparationCandidate) async throws -> MeetingPreparationThreadReport {
        try validate()
        guard candidates[candidate.thread] == candidate else { throw MeetingPreparationServiceError.invalidSource }
        guard reportAttempts < Self.reportLimit else { throw MeetingPreparationServiceError.reportLimit }
        guard access.scope.canUsePlan else { throw AIProviderError.signInRequired }
        guard access.modelReady, !access.modelID.isEmpty else { throw AssistantError.noModel }
        reportAttempts += 1
        let args: AIJSON = .object(["account_id": .string(candidate.thread.accountID), "thread_id": .string(candidate.thread.threadID)])
        let read = try await tools.execute(AIToolCall(id: UUID().uuidString, namespace: "tern", name: "read_thread",
            arguments: try args.jsonString()))
        try validate()
        guard let source = try await loadSource(candidate.thread) else { throw MeetingPreparationServiceError.sourceUnavailable }
        try validate()
        let current = try MeetingPreparationEvidence.detail(source.detail, read: read, thread: candidate.thread)
        // The summary consumes this exact full read. Metadata hydration must not
        // trigger a second full read or change the evidence underneath it.
        let captured = AssistantToolSession(definitions: [], execute: { [isValid] call in
            try Task.checkCancellation()
            guard isValid() else { throw AssistantError.accessChanged }
            guard call.name == "read_thread", let fields = try AIJSON.decode(Data(call.arguments.utf8)).objectValue,
                  fields["account_id"]?.stringValue == candidate.thread.accountID,
                  fields["thread_id"]?.stringValue == candidate.thread.threadID else { throw AssistantError.invalidTool }
            return read
        })
        let service = AssistantSummaryService(provider: provider, model: access.modelID, tools: captured, isScopeValid: isValid)
        let report = try await service.report(thread: candidate.thread)
        try validate()
        try Self.validate(report: report, detail: current, thread: candidate.thread)
        let attachments = Self.attachments(in: current)
        return MeetingPreparationThreadReport(candidate: candidate, report: report, detail: current,
            revision: source.revision, attachments: attachments)
    }

    private func validate() throws {
        try Task.checkCancellation()
        guard isValid() else { throw AssistantError.accessChanged }
        guard access.scope.calendarScope.allows(.init(accountID: event.accountID, calendarID: event.calendarID), details: true) else {
            throw MeetingPreparationServiceError.calendarDetailsRequired
        }
        guard !access.scope.accountIDs.isEmpty else { throw MeetingPreparationServiceError.noMailAccess }
    }

    static func validate(report: ThreadSummaryReport, detail: ThreadDetail, thread: ThreadKey) throws {
        guard detail.thread.accountID == thread.accountID, detail.thread.id == thread.threadID,
              detail.messages.allSatisfy({ $0.record.accountID == thread.accountID && $0.record.threadID == thread.threadID }) else {
            throw MeetingPreparationServiceError.invalidSource
        }
        let messages = Set(detail.messages.map(\.id))
        try report.validateMessages(messages)
        guard !report.sources.isEmpty,
              report.sources.allSatisfy({ !$0.isCalendar && $0.accountID == thread.accountID && $0.threadID == thread.threadID
                  && $0.partID == nil && $0.messageID.map(messages.contains) == true }) else {
            throw MeetingPreparationServiceError.invalidSource
        }
        let ids = Set(report.sources.map(\.id))
        let citations = [report.summary.sourceIDs] + report.summary.decisions.map(\.sourceIDs) + report.summary.openTasks.map(\.sourceIDs)
        guard citations.allSatisfy({ !$0.isEmpty && Set($0).isSubset(of: ids) }) else { throw MeetingPreparationServiceError.invalidSource }
    }

    static func attachments(in detail: ThreadDetail) -> [MeetingPreparationAttachment] {
        var seen = Set<String>()
        return detail.messages.flatMap { message in
            message.attachments.compactMap { attachment -> MeetingPreparationAttachment? in
                guard attachment.accountID == message.record.accountID, attachment.messageID == message.id,
                      !attachment.isInline, !attachment.filename.isEmpty else { return nil }
                let source = AssistantSource(accountID: message.record.accountID, threadID: message.record.threadID,
                    messageID: message.id, partID: attachment.partID, title: attachment.filename)
                guard seen.insert(source.id).inserted else { return nil }
                return MeetingPreparationAttachment(source: source, filename: attachment.filename, sender: message.record.sender,
                    date: message.record.date, size: attachment.size, mimeType: attachment.mimeType)
            }
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}
