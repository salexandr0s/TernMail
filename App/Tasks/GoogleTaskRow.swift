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
                            .foregroundStyle(task.isCompleted || isHovered ? Color.accentColor : Color.secondary)
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
            .ternHover(isEnabled: !isBusy, radius: Tokens.Radius.md)

            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(task.title.isEmpty ? "Untitled task" : task.title)
                            .font(.body.weight(task.isCompleted ? .regular : .medium))
                            .strikethrough(task.isCompleted)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        let preview = Self.visibleNotes(task.notes ?? "")
                        if !preview.isEmpty && !task.isCompleted {
                            Text(preview).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help(task.title)
                .accessibilityLabel("Edit task: \(task.title)")
                .accessibilityIdentifier("google-task-edit-\(task.id)")

                if !task.isCompleted && (task.dueDay != nil || Self.emailURL(task.notes ?? "") != nil) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.s2) { metadata }
                        VStack(alignment: .leading, spacing: Tokens.Space.s1_5) { metadata }
                    }
                }
                if let parentTitle, !task.isCompleted {
                    Label(parentTitle, systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help("Subtask of \(parentTitle)")
                        .accessibilityLabel("Subtask of \(parentTitle)")
                }
            }
            .padding(.vertical, Tokens.Space.s1_5)
            .frame(maxWidth: .infinity, alignment: .leading)

            options
        }
        .padding(.vertical, Tokens.Space.s1_5)
        .padding(.horizontal, Tokens.Space.s2)
        .background(isHovered ? Color.accentColor.opacity(Tokens.Opacity.hover) : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .onHover { isHovered = $0 }
        .ternAnimation(value: isHovered)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var metadata: some View {
        if let due = task.dueDay {
            Label {
                Text(dueLabel(due)).foregroundStyle(.primary)
            } icon: {
                Image(systemName: isOverdue(due) ? "clock" : "calendar").foregroundStyle(dueColor(due))
            }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, Tokens.Space.s1_5)
                .padding(.vertical, Tokens.Space.s0_5)
                .background(dueColor(due).opacity(Tokens.Opacity.wash), in: Capsule())
                .fixedSize()
                .accessibilityLabel("Due \(dueLabel(due))")
        }
        if let source = Self.emailURL(task.notes ?? "") {
            Button { openURL(source) } label: {
                Label(Self.emailSubject(task.notes ?? "") ?? "Source email", systemImage: "envelope")
                    .font(.caption2).lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isBusy)
            .help(Self.emailSubject(task.notes ?? "") ?? "Open source email")
            .accessibilityLabel("Open source email: \(Self.emailSubject(task.notes ?? "") ?? task.title)")
            .accessibilityIdentifier("google-task-email-\(task.id)")
        }
    }

    private var options: some View {
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
        .foregroundStyle(isHovered ? Color.primary : Color.secondary).disabled(isBusy)
        .help("Task options").accessibilityLabel("Options for \(task.title)")
    }

    private func dueLabel(_ day: String) -> String {
        guard let date = GoogleTaskDateCoding.date(day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let label = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: .now)
            ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(date: .abbreviated, time: .omitted)
        return isOverdue(day) ? "Overdue · \(label)" : label
    }

    private func isOverdue(_ day: String) -> Bool { day < GoogleTaskDateCoding.string(.now) }

    private func dueColor(_ day: String) -> Color {
        if isOverdue(day) { return Tokens.Status.error }
        if day == GoogleTaskDateCoding.string(.now) { return .accentColor }
        return .secondary
    }

    static func visibleNotes(_ notes: String) -> String {
        GoogleTaskNotes(notes).text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("Tern task reference: ") && !$0.hasPrefix("tern://") && !$0.hasPrefix("https://mail.google.com/") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func emailSubject(_ notes: String) -> String? {
        GoogleTaskNotes(notes).footer.components(separatedBy: .newlines)
            .first { $0.hasPrefix("Email: ") }.map { String($0.dropFirst("Email: ".count)) }
    }

    static func emailURL(_ notes: String) -> URL? {
        notes.components(separatedBy: .newlines).compactMap { value -> URL? in
            guard let url = URL(string: value), MailLink(url: url) != nil else { return nil }
            return url
        }.first
    }
}
