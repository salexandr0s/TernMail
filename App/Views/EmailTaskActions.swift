import GmailAPI
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

    static func calendarSuggestion(_ item: EmailCalendarItem, detail: ThreadDetail, calendar: Calendar,
                                   accountEmail: String?) -> TaskCreationRequest? {
        guard item.canReview, item.kind != .cancelled,
              detail.messages.contains(where: { $0.id == item.messageID }) else { return nil }
        let presentation = EmailCalendarPresentation(item: item, calendar: calendar)
        let source = source(accountID: detail.thread.accountID, threadID: detail.thread.id,
            messageID: item.messageID, subject: detail.thread.subject, accountEmail: accountEmail)
        // Tasks stores a day only. Match the day displayed on the suggestion and
        // keep the event's time and context in its notes.
        let dueDate = presentation.start.map { GoogleTaskDateCoding.string($0, timeZone: calendar.timeZone) }
        let notes = [presentation.dateLine, presentation.location, presentation.originalTimeZoneLine,
                     item.evidence.isEmpty ? nil : item.evidence]
            .compactMap { $0 }.joined(separator: "\n\n")
        return TaskCreationRequest(title: presentation.title, notes: notes, dueDate: dueDate, source: source,
            deduplicationKey: "calendar-suggestion\u{0}\(detail.thread.id)\u{0}\(item.id)")
    }

    private static func source(accountID: String, threadID: String, messageID: String?, subject: String,
                               accountEmail: String?) -> TaskEmailSource {
        let link = MailLink(accountID: accountID, threadID: threadID, messageID: messageID)
        return TaskEmailSource(accountID: accountID, threadID: threadID, messageID: messageID, subject: subject,
            gmailURL: accountEmail.flatMap { link.gmailURL(email: $0) })
    }
}

struct EmailTaskAddButton: View {
    let request: TaskCreationRequest
    let model: GoogleTasksModel
    let onAdd: (TaskCreationRequest) -> Void

    private var state: TaskCreationState { model.creationState(for: request) }
    private var isDisabled: Bool { model.isCreating || state == .added }

    private var actionLabel: String {
        switch state {
        case .idle: "Add to Google Tasks"
        case .adding: "Adding to Google Tasks"
        case .added: "Added to Google Tasks"
        case .uncertain: "Check whether this task was added"
        }
    }

    var body: some View {
        Button { onAdd(request) } label: {
            ZStack {
                if state == .adding { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: state == .added ? "checkmark" : state == .uncertain ? "arrow.clockwise" : "plus")
                        .font(.body.weight(.medium))
                        .foregroundStyle(state == .added ? Color.secondary : Color.accentColor)
                }
            }
            .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .ternHover(isEnabled: !isDisabled)
        .help(actionLabel)
        .accessibilityLabel("\(actionLabel): \(request.title)")
    }
}
