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
    /// When this value was made. A due date draws as Today, Tomorrow or Overdue by the current
    /// day, so rows made on different days must not compare equal.
    private let createdAt = Date.now
    @Environment(\.openURL) private var openURL
    /// The buttons bind their focus only while Keyboard navigation lets them take it.
    @Environment(\.buttonsTakeKeyboardFocus) private var buttonsTakeFocus
    @State private var isHovered = false
    @FocusState private var focusedControl: Control?
    @AccessibilityFocusState private var accessibleControl: Control?

    private enum Control: Hashable { case complete, title, source, edit, delete }
    private var showsActions: Bool { !isPending && (isHovered || focusedControl != nil || accessibleControl != nil) }
    /// A write to this task is waiting for Google, so what the row shows isn't saved yet. The
    /// placeholder for a task being added keeps its own look.
    private var contentOpacity: Double { isBusy && !isPending ? Tokens.Opacity.disabled : 1 }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Button(action: onComplete) {
                // The symbol keeps its place, dimmed, while a write runs. The spinner joins it only
                // if the write outlasts the loading delay, so a short one never flashes a spinner.
                ZStack {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2.weight(.light))
                        .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                        .opacity(isBusy ? Tokens.Opacity.disabled : 1)
                    if isBusy { ProgressView().controlSize(.small).ternDelayedLoading() }
                }
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .focused($focusedControl, equals: .complete, whileButtonsTakeFocus: buttonsTakeFocus)
            .accessibilityFocused($accessibleControl, equals: .complete)
            .help(task.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel("\(isPending ? "Adding task" : task.isCompleted ? "Mark incomplete" : "Complete"): \(task.title)")
            .accessibilityValue(isBusy ? "Saving" : "")
            .accessibilityIdentifier("google-task-complete-\(task.id)")
            .ternHover(isEnabled: !isBusy, radius: Tokens.Radius.md)

            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                if isPending {
                    taskText
                } else {
                    Button(action: onEdit) { taskText }
                        .buttonStyle(.plain)
                        .disabled(isBusy || !allowsEditing)
                        .focused($focusedControl, equals: .title, whileButtonsTakeFocus: buttonsTakeFocus)
                        .accessibilityFocused($accessibleControl, equals: .title)
                        .help(task.title)
                        .accessibilityLabel("Edit task: \(task.title)")
                        .accessibilityIdentifier("google-task-edit-\(task.id)")
                }

                sourceLink
                if let parentTitle, !task.isCompleted {
                    Label(parentTitle, systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("Subtask of \(parentTitle)")
                        .accessibilityLabel("Subtask of \(parentTitle)")
                }
            }
            .padding(.vertical, Tokens.Space.s1_5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(contentOpacity)

            VStack(alignment: .trailing, spacing: Tokens.Space.s0_5) {
                dueTile
                actions
            }
            .opacity(contentOpacity)
        }
        .padding(.vertical, Tokens.Space.s1_5)
        .padding(.horizontal, Tokens.Space.s2)
        .background(showsActions ? Color.primary.opacity(Tokens.Opacity.hover) : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOnHover { isHovered = $0 }
        .ternAnimation(value: showsActions)
        .ternAnimation(value: isBusy, duration: Tokens.Motion.fast)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-task-row-\(task.id)")
        .contentShape(Rectangle())
        .contextMenu {
            if !isPending {
                Group {
                    Button(task.isCompleted ? "Mark Incomplete" : "Mark Complete",
                           systemImage: task.isCompleted ? "circle" : "checkmark.circle", action: onComplete)
                    Button("Edit Task…", systemImage: "pencil", action: onEdit)
                        .disabled(!allowsEditing)
                    if let source = Self.emailURL(task.notes ?? "") {
                        Button("Open Source Email", systemImage: "envelope") { openURL(source) }
                    }
                    Divider()
                    Button("Delete Task…", systemImage: "trash", role: .destructive, action: onDelete)
                }
                .disabled(isBusy)
            }
        }
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
                Text(preview).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .help(preview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var dueTile: some View {
        if let due = task.dueDay {
            let date = GoogleTaskDateCoding.date(due)
            let fullDate = date?.formatted(date: .complete, time: .omitted) ?? due
            CalendarDateTile(
                month: date?.formatted(.dateTime.month(.abbreviated)).uppercased(),
                day: date?.formatted(.dateTime.day()),
                size: Tokens.CalendarDate.taskSize,
                isMuted: task.isCompleted
            )
                .overlay(alignment: .topTrailing) {
                    if !task.isCompleted, isOverdue(due) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: Tokens.ConversationHeader.statusBadge))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Tokens.Status.error, Tokens.Surface.primary)
                            .background(Tokens.Surface.primary, in: Circle())
                            .offset(x: Tokens.Space.s1, y: -Tokens.Space.s1)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.top, Tokens.Space.s1_5)
                .help(task.isCompleted ? fullDate : "\(dueLabel(due)) · \(fullDate)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(task.isCompleted ? "Due date" : "Due \(dueLabel(due))")
                .accessibilityValue(fullDate)
                .accessibilityIdentifier("google-task-due-\(task.id)")
        }
    }

    @ViewBuilder private var sourceLink: some View {
        if let source = Self.emailURL(task.notes ?? "") {
            Button { openURL(source) } label: {
                Label(Self.emailSubject(task.notes ?? "") ?? "Source email", systemImage: "envelope")
                    .font(.caption).lineLimit(1)
                    .padding(.vertical, Tokens.Space.s0_5)
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isBusy)
            .focused($focusedControl, equals: .source, whileButtonsTakeFocus: buttonsTakeFocus)
            .accessibilityFocused($accessibleControl, equals: .source)
            .help(Self.emailSubject(task.notes ?? "") ?? "Open source email")
            .accessibilityLabel("Open source email: \(Self.emailSubject(task.notes ?? "") ?? task.title)")
            .accessibilityIdentifier("google-task-email-\(task.id)")
            .ternHover(isEnabled: !isBusy, pointer: .link)
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
        .focused($focusedControl, equals: control, whileButtonsTakeFocus: buttonsTakeFocus)
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

/// Rows compare by what they draw and by the task their actions act on, so a parent can use
/// `.equatable()` to leave unchanged rows alone. The actions themselves are not compared. Use
/// `.equatable()` only where they depend on the task and on state they read when they run, and on
/// nothing else the parent could change while the row stays equal.
extension GoogleTaskRow: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.task == rhs.task && lhs.parentTitle == rhs.parentTitle && lhs.isBusy == rhs.isBusy
            && lhs.isPending == rhs.isPending && lhs.allowsEditing == rhs.allowsEditing
            && (lhs.task.due == nil || Calendar.current.isDate(lhs.createdAt, inSameDayAs: rhs.createdAt))
    }
}
