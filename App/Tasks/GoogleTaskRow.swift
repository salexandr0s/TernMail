import GmailAPI
import MessageContent
import SwiftUI

struct GoogleTaskRow: View {
    let task: GoogleTask
    let parentTitle: String?
    let isBusy: Bool
    let onComplete: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Button(action: onComplete) {
                ZStack {
                    if isBusy { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(task.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel("\(task.isCompleted ? "Mark incomplete" : "Complete"): \(task.title)")
            .accessibilityIdentifier("google-task-complete-\(task.id)")

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                    if let parentTitle {
                        Label(parentTitle, systemImage: "arrow.turn.down.right")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(task.title.isEmpty ? "Untitled task" : task.title)
                        .font(.callout.weight(task.isCompleted ? .regular : .medium))
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let due = task.dueDay, !task.isCompleted {
                        Label(dueLabel(due), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(isOverdue(due) ? Tokens.Status.error : Color.secondary)
                    }
                    let preview = Self.visibleNotes(task.notes ?? "")
                    if !preview.isEmpty {
                        Text(preview).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                .padding(.vertical, Tokens.Space.s1_5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("Edit task: \(task.title)")
            .accessibilityIdentifier("google-task-edit-\(task.id)")

            Menu {
                Button("Edit Task…", systemImage: "pencil", action: onEdit)
                if let source = Self.emailURL(task.notes ?? "") {
                    Button("Open Email", systemImage: "envelope") { openURL(source) }
                }
                Divider()
                Button("Delete Task…", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: Tokens.Space.s6, height: Tokens.Control.iconButton)
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary).disabled(isBusy)
            .help("Task options").accessibilityLabel("Options for \(task.title)")
        }
        .padding(.vertical, Tokens.Space.s2)
        .padding(.horizontal, Tokens.Space.s2)
        .background(isHovered ? Color.primary.opacity(Tokens.Opacity.hover) : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private func dueLabel(_ day: String) -> String {
        guard let date = GoogleTaskDateCoding.date(day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let label = date.formatted(date: .abbreviated, time: .omitted)
        return isOverdue(day) ? "Overdue · \(label)" : label
    }

    private func isOverdue(_ day: String) -> Bool { day < GoogleTaskDateCoding.string(.now) }

    static func visibleNotes(_ notes: String) -> String {
        notes.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("Tern task reference: ") && !$0.hasPrefix("tern://") && !$0.hasPrefix("https://mail.google.com/") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func emailURL(_ notes: String) -> URL? {
        notes.components(separatedBy: .newlines).compactMap { value -> URL? in
            guard let url = URL(string: value), MailLink(url: url) != nil else { return nil }
            return url
        }.first
    }
}
