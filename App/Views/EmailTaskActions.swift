import MailStore
import MessageContent
import SwiftUI
import TernAI

enum EmailTaskRequest {
    static func selection(_ text: String, message: MessageDetail, accountEmail: String?) -> TaskCreationRequest? {
        let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return nil }
        let title = selected.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let excerpt = String(selected.prefix(6_000)) + (selected.count > 6_000 ? "\n[Selection shortened]" : "")
        let source = source(accountID: message.record.accountID, threadID: message.record.threadID,
            messageID: message.id, subject: message.record.subject, accountEmail: accountEmail)
        return TaskCreationRequest(title: String(title.prefix(160)), notes: title == selected && title.count <= 160 ? "" : excerpt,
            source: source, deduplicationKey: "selection\u{0}\(message.id)\u{0}\(selected)")
    }

    static func suggestion(_ task: AssistantSummary.OpenTask, report: ThreadSummaryReport,
                           detail: ThreadDetail, accountEmail: String?) -> TaskCreationRequest {
        let supporting = report.sources.first {
            task.sourceIDs.contains($0.id) && $0.accountID == detail.thread.accountID && $0.threadID == detail.thread.id
        }
        let messageID = supporting?.messageID.flatMap { id in detail.messages.contains { $0.id == id } ? id : nil }
        let source = source(accountID: detail.thread.accountID, threadID: detail.thread.id,
            messageID: messageID, subject: detail.thread.subject, accountEmail: accountEmail)
        let title = task.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let owner = (task.owner ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return TaskCreationRequest(title: title, notes: task.owner.map { "Owner: \($0)" } ?? "",
            dueDate: task.dueDate, source: source, deduplicationKey: "suggestion\u{0}\(detail.thread.id)\u{0}\(identity)\u{0}\(owner)")
    }

    private static func source(accountID: String, threadID: String, messageID: String?, subject: String,
                               accountEmail: String?) -> TaskEmailSource {
        let link = MailLink(accountID: accountID, threadID: threadID, messageID: messageID)
        return TaskEmailSource(accountID: accountID, threadID: threadID, messageID: messageID, subject: subject,
            gmailURL: accountEmail.flatMap { link.gmailURL(email: $0) })
    }
}

struct SummaryTaskAddButton: View {
    let request: TaskCreationRequest
    let model: GoogleTasksModel
    let onAdd: (TaskCreationRequest) -> Void

    private var state: TaskCreationState { model.creationState(for: request) }

    var body: some View {
        Button { onAdd(request) } label: {
            HStack(spacing: Tokens.Space.s1_5) {
                if state == .adding { ProgressView().controlSize(.mini) }
                else { Image(systemName: state == .added ? "checkmark" : state == .uncertain ? "arrow.clockwise" : "plus") }
                Text(state == .added ? "Added to Tasks" : state == .adding ? "Adding…" : state == .uncertain ? "Check Tasks" : "Add to Tasks")
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isCreating || state == .added)
        .help(state == .added ? "Saved in Google Tasks" : "Add this suggestion to Google Tasks")
        .accessibilityLabel(state == .added ? "Added to Google Tasks: \(request.title)" : "Add to Google Tasks: \(request.title)")
    }
}
