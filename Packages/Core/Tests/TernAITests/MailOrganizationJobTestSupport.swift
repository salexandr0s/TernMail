import Foundation
@testable import TernAI

struct OrganizationJobProvider: AIProvider {
    let script: OrganizationJobScript
    func models() async throws -> [AIModel] { [] }
    func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.completed(try await script.answer(request)))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor OrganizationJobScript {
    enum Mode: Sendable, Equatable { case finance, workflow, hierarchy }
    let mode: Mode
    var failAuditOnce: Bool
    let invalidMerge: Bool
    private(set) var requests: [AIRequest] = []

    init(mode: Mode = .finance, failAuditOnce: Bool = false, invalidMerge: Bool = false) {
        self.mode = mode; self.failAuditOnce = failAuditOnce; self.invalidMerge = invalidMerge
    }

    func answer(_ request: AIRequest) throws -> AIResponse {
        requests.append(request)
        let input = try Self.input(request)
        let value: AIJSON
        switch input["stage"]?.stringValue {
        case "discovery":
            let messages = input["messages"]?.arrayValue ?? []
            if mode == .hierarchy {
                let groups = stride(from: 0, to: messages.count, by: 5).map { start in
                    let ids = messages[start..<min(start + 5, messages.count)].compactMap { $0["id"]?.stringValue }
                    return Self.draft("Theme \(start)", ids: ids)
                }
                value = .object(["categories": .array(groups)])
            } else {
                let chosen = messages.filter {
                    mode == .workflow ? $0["subject"] == .string("Request") : ["Invoice", "Remove on audit"].contains($0["subject"]?.stringValue ?? "")
                }
                let ids = chosen.compactMap { $0["id"]?.stringValue }
                value = .object(["categories": .array(ids.isEmpty ? [] : [Self.draft(mode == .workflow ? "Action" : "Money", ids: ids,
                                                                                   kind: mode == .workflow ? "action" : "topic")])])
            }
        case "consolidation":
            let sources = input["themes"]?.arrayValue ?? []
            let earlier = input["previously_chosen_labels"]?.arrayValue ?? []
            let linked = (input["catalogue"]?.arrayValue ?? []).filter { $0["type"] == .string("rule") }
                .flatMap { $0["labels"]?.arrayValue ?? [] }
            let target = (earlier + linked).first { $0["id"] == .string("saved-finance") }
            let name = target?["name"]?.stringValue ?? (mode == .workflow ? "Action" : "Finance")
            var ids = sources.compactMap { $0["source_id"]?.stringValue }
            if invalidMerge { ids.append("invented-source") }
            value = .object(["categories": .array([.object([
                "name": .string(name), "explanation": .string("Messages about the same subject."),
                "kind": .string(mode == .workflow ? "action" : "topic"), "source_ids": .array(ids.map(AIJSON.string)),
                "existing_label_id": target?["id"] ?? .null,
            ])])])
        case "audit":
            if failAuditOnce { failAuditOnce = false; throw AIProviderError.network }
            let id = input["taxonomy"]?.arrayValue?.first?["category_id"]?.stringValue ?? ""
            let messages = (input["messages"]?.arrayValue ?? []).filter {
                switch mode {
                case .finance: $0["subject"] == .string("Invoice")
                case .workflow: $0["subject"] == .string("Request")
                case .hierarchy: true
                }
            }
            let ids = messages.compactMap { $0["id"]?.stringValue }
            value = .object(["assignments": .array(ids.isEmpty ? [] : [.object([
                "category_id": .string(id), "message_ids": .array(ids.map(AIJSON.string)),
            ])])])
        case "rule_review":
            value = .object(["approved_senders": .array((input["senders"]?.arrayValue ?? []).compactMap { $0["sender"] })])
        default:
            throw MailOrganizationError.invalidResponse
        }
        return AIResponse(output: [], text: try value.jsonString(), toolCalls: [])
    }

    static func input(_ request: AIRequest) throws -> AIJSON {
        guard let content = request.input.first?["content"]?.stringValue else { throw AIProviderError.invalidRequest }
        return try AIJSON.decode(Data(content.utf8))
    }

    private static func draft(_ name: String, ids: [String], kind: String = "topic") -> AIJSON {
        .object(["name": .string(name), "explanation": .string("Messages about the same subject."), "kind": .string(kind),
                 "message_ids": .array(ids.map(AIJSON.string))])
    }
}

actor OrganizationCheckpointRecorder {
    private(set) var checkpoint: OrganizationAnalysisCheckpoint?
    func append(_ checkpoint: OrganizationAnalysisCheckpoint) { self.checkpoint = checkpoint }
}

func organizationJobMail(_ id: Int, count: Int = 201, subject: String = "Unassigned", sender: String? = nil,
                         sent: Bool = false, recipients: [String] = ["owner@example.invalid"],
                         thread: String? = nil, snippet: String = "Message preview") -> OrganizationEmail {
    .init(id: "m\(id)", threadID: thread ?? "t\(id)", sender: sender ?? "person\(id)@example.invalid", recipients: recipients,
          subject: subject, snippet: snippet, date: Date(timeIntervalSince1970: Double(count - id)), isSent: sent,
          labelNames: [], hasMailingListHeaders: sender == "billing@example.invalid", isAutomated: false)
}

func organizationJobContext() -> OrganizationContext {
    .init(labels: [.init(id: "saved-finance", name: "Accounts & Finance")],
          rules: [.init(id: "old-rule", labelIDs: ["saved-finance"], criteria: "from:old@example.invalid", actions: "Add saved-finance")])
}
