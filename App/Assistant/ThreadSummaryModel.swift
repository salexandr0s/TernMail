import CryptoKit
import Foundation
import MailStore
import Observation
import TernAI

struct ThreadSummaryReport: Equatable, Sendable {
    let summary: AssistantSummary
    let sources: [AssistantSource]
    let hasPartialCoverage: Bool
    let messageIDs: Set<String>
    let totalMessages: Int?

    init(summary: AssistantSummary, sources: [AssistantSource], hasPartialCoverage: Bool,
         messageIDs: Set<String>? = nil, totalMessages: Int? = nil) {
        self.summary = summary; self.sources = sources; self.hasPartialCoverage = hasPartialCoverage
        self.messageIDs = messageIDs ?? Set(sources.compactMap(\.messageID))
        self.totalMessages = totalMessages
    }

    func validateMessages(_ expected: Set<String>?) throws {
        guard let expected else { return }
        guard messageIDs.isSubset(of: expected), totalMessages.map({ $0 == expected.count }) ?? true else {
            throw ThreadSummaryError.sourceChanged
        }
    }
}

enum ThreadSummaryError: Error { case sourceChanged }

enum ThreadSummaryAvailability: Equatable {
    case ready
    case loading
    case unavailable(reason: String, action: String)
}

@MainActor
@Observable
final class ThreadSummaryModel {
    private(set) var report: ThreadSummaryReport?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var requestID = UUID()

    /// Gmail message content is immutable except for drafts, whose metadata or
    /// message ID changes on save. Read flags, labels and local body hydration
    /// do not change the source read directly by the summary service.
    static func revision(for detail: ThreadDetail) -> String {
        var hasher = SHA256()
        func append(_ value: String) {
            hasher.update(data: Data("\(value.utf8.count):\(value)".utf8))
        }
        append(detail.thread.accountID)
        append(detail.thread.id)
        append(String(detail.thread.messageCount))
        for message in detail.messages.sorted(by: { $0.id < $1.id }) {
            let record = message.record
            [record.id, record.subject, record.sender, record.recipients, record.cc ?? "",
             String(record.date.timeIntervalSince1970), record.snippet, String(record.sizeEstimate),
             message.draftID ?? ""].forEach(append)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    func load(key: ThreadKey, revision: String, assistant: AssistantModel, forceRefresh: Bool = false,
              expectedMessageIDs: Set<String>? = nil) async {
        clear()
        let id = requestID
        let accessRevision = assistant.summaryAccessRevision
        guard assistant.summaryAvailability(for: key) == .ready, !Task.isCancelled else { return }
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let result = try await assistant.readerSummary(thread: key, revision: revision, forceRefresh: forceRefresh,
                expectedMessageIDs: expectedMessageIDs)
            guard requestID == id, !Task.isCancelled,
                  assistant.summaryAccessRevision == accessRevision,
                  assistant.summaryAvailability(for: key) == .ready else { return }
            report = result
        } catch {
            guard requestID == id, !Task.isCancelled, !(error is CancellationError),
                  assistant.summaryAccessRevision == accessRevision,
                  assistant.summaryAvailability(for: key) == .ready else { return }
            errorMessage = error is ThreadSummaryError
                ? "Conversation changed. Sync mail and try again."
                : "Couldn’t summarize this conversation."
        }
    }

    func clear() {
        requestID = UUID()
        report = nil
        errorMessage = nil
        isLoading = false
    }
}

/// Session memory only. Scope selection may change without discarding reusable
/// results, but access loss, account replacement and connection changes evict them.
struct ThreadSummaryCache {
    struct Access: Equatable {
        let accountInstances: [String: String]
        let connectionRevision: Int
        let canUsePlan: Bool
        let modelID: String
    }
    struct Key: Equatable {
        let thread: ThreadKey
        let accountInstance: String
        let connectionRevision: Int
        let modelID: String
        let sourceRevision: String
    }
    private var access: Access?
    private var entries: [(key: Key, report: ThreadSummaryReport)] = []
    private let capacity = 16

    mutating func updateAccess(_ current: Access) {
        if access != current { removeAll(); access = current }
    }

    mutating func removeAll() { entries.removeAll() }

    mutating func report(for key: Key) -> ThreadSummaryReport? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.report
    }

    mutating func insert(_ report: ThreadSummaryReport, for key: Key) {
        entries.removeAll { $0.key == key }
        entries.append((key, report))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
