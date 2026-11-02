import GmailAPI
import MessageContent
import SwiftUI

struct GoogleTaskRow: View {
    let task: GoogleTask
    let parentTitle: String?
    let isBusy: Bool
    var isPending = false
    var allowsEditing = true
    let onComplete: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var isHovered = false
    @FocusState private var focusedControl: Control?
    @AccessibilityFocusState private var accessibleControl: Control?

    private enum Control: Hashable { case complete, title, source, edit, delete }
    private var showsActions: Bool { !isPending && (isHovered || focusedControl != nil || accessibleControl != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                completionButton
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    if isPending {
                        taskText
                    } else {
                        Button(action: onEdit) { taskText }
                            .buttonStyle(.plain)
                            .disabled(isBusy || !allowsEditing)
                            .focused($focusedControl, equals: .title)
                            .accessibilityFocused($accessibleControl, equals: .title)
                            .help(task.title)
                            .accessibilityLabel("Edit task: \(task.title)")
                            .accessibilityIdentifier("google-task-edit-\(task.id)")
                    }
                    if let parentTitle, !task.isCompleted {
                        Label(parentTitle, systemImage: "arrow.turn.down.right")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            .help("Subtask of \(parentTitle)")
                            .accessibilityLabel("Subtask of \(parentTitle)")
                    }
                }
                .padding(.top, Tokens.Space.s1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    metadata
                    Spacer(minLength: 0)
                    actions
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                    metadata
                    actions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.leading, Tokens.Control.iconButton + Tokens.Space.s2)
        }
        .padding(.vertical, Tokens.Space.s2)
        .padding(.horizontal, Tokens.Space.s2)
        .background(showsActions ? Color.primary.opacity(Tokens.Opacity.hover) : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .onHover { isHovered = $0 }
        .ternAnimation(value: showsActions)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-task-row-\(task.id)")
    }

    private var completionButton: some View {
        Button(action: onComplete) {
            ZStack {
                if isBusy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                }
            }
            .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .focused($focusedControl, equals: .complete)
        .accessibilityFocused($accessibleControl, equals: .complete)
        .help(task.isCompleted ? "Mark incomplete" : "Mark complete")
        .accessibilityLabel("\(isPending ? "Adding task" : task.isCompleted ? "Mark incomplete" : "Complete"): \(task.title)")
        .accessibilityIdentifier("google-task-complete-\(task.id)")
        .ternHover(isEnabled: !isBusy, radius: Tokens.Radius.md)
    }

    private var taskText: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(task.title.isEmpty ? "Untitled task" : task.title)
                .font(.body.weight(task.isCompleted ? .regular : .semibold))
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            let preview = Self.visibleNotes(task.notes ?? "")
            if !preview.isEmpty && !task.isCompleted {
                Text(preview).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metadata: some View {
        if let due = task.dueDay, !task.isCompleted {
            Label {
                Text(dueLabel(due)).foregroundStyle(.primary)
            } icon: {
                Image(systemName: isOverdue(due) ? "clock" : "calendar").foregroundStyle(dueColor(due))
            }
                .font(.callout.weight(.medium))
                .padding(.horizontal, Tokens.Space.s1_5)
                .padding(.vertical, Tokens.Space.s0_5)
                .background(dueColor(due).opacity(Tokens.Opacity.wash), in: Capsule())
                .fixedSize()
                .accessibilityLabel("Due \(dueLabel(due))")
        }
        if let source = Self.emailURL(task.notes ?? "") {
            Button { openURL(source) } label: {
                Label(Self.emailSubject(task.notes ?? "") ?? "Source email", systemImage: "envelope")
                    .font(.callout).lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isBusy)
            .focused($focusedControl, equals: .source)
            .accessibilityFocused($accessibleControl, equals: .source)
            .help(Self.emailSubject(task.notes ?? "") ?? "Open source email")
            .accessibilityLabel("Open source email: \(Self.emailSubject(task.notes ?? "") ?? task.title)")
            .accessibilityIdentifier("google-task-email-\(task.id)")
        }
    }

    private var actions: some View {
        HStack(spacing: Tokens.Space.s0_5) {
            action("Edit task", symbol: "pencil", control: .edit, perform: onEdit)
            action("Delete task", symbol: "trash", control: .delete, perform: onDelete)
        }
        .disabled(isBusy)
        .accessibilityHidden(isPending)
    }

    private func action(_ title: String, symbol: String, control: Control, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.callout)
                .opacity(showsActions ? 1 : 0)
                .frame(width: Tokens.Space.s6, height: Tokens.Control.iconButton)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .disabled(control == .edit && !allowsEditing)
        .focused($focusedControl, equals: control)
        .accessibilityFocused($accessibleControl, equals: control)
        .ternHover(isEnabled: !isBusy)
        .help(title).accessibilityLabel("\(title): \(task.title)")
        .accessibilityIdentifier("google-task-\(control == .edit ? "edit-button" : "delete")-\(task.id)")
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
