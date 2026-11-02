import Foundation

/// An extracted task keeps the retrieved email identity through edits and retries.
struct AssistantTaskResult: Identifiable, Sendable, Equatable {
    let source: AssistantSource
    let title: String
    let owner: String?
    let notes: String
    let dueDate: String?
    let evidence: String

    var id: String { request.reference }

    var request: TaskCreationRequest {
        let identity = Self.normalized(title)
        let ownerIdentity = Self.normalized(owner ?? "")
        let detail = [owner.map { "Owner: \($0)" }, notes.isEmpty ? nil : notes,
                      evidence.isEmpty ? nil : "From email:\n\(evidence)"]
            .compactMap { $0 }.joined(separator: "\n\n")
        return TaskCreationRequest(title: title, notes: detail, dueDate: dueDate,
            source: TaskEmailSource(accountID: source.accountID, threadID: source.threadID,
                                    messageID: source.messageID, subject: source.title),
            deduplicationKey: "suggestion\u{0}\(source.threadID)\u{0}\(identity)\u{0}\(ownerIdentity)")
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
