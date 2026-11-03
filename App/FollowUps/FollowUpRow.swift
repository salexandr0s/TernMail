import MailStore
import SwiftUI

struct FollowUpRow: View {
    let entry: CommitmentEntry
    let accountName: String
    let checkState: FollowUpReplyCheckState?
    let now: Date
    let isBusy: Bool
    let onEdit: () -> Void
    let onComplete: () -> Void
    let onDismiss: () -> Void
    let onReopen: () -> Void
    let onSnooze: (Date) -> Void
    let onOpenSource: () -> Void
    let onDraft: () -> Void

    private var record: CommitmentRecord { entry.record }
    private var isOpen: Bool { record.status == .open }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Button(action: isOpen ? onComplete : onReopen) {
                Group {
                    if isBusy { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: completionSymbol)
                            .font(.title2.weight(.light))
                            .foregroundStyle(record.status == .completed ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(isOpen ? "Complete follow-up" : "Reopen follow-up")
            .accessibilityLabel("\(isOpen ? "Complete" : "Reopen"): \(record.title)")
            .accessibilityIdentifier("follow-up-status-\(record.id)")

            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Button(action: onEdit) {
                    Text(record.title)
                        .font(.body.weight(isOpen ? .medium : .regular))
                        .foregroundStyle(isOpen ? .primary : .secondary)
                        .strikethrough(record.status == .completed)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel("Edit follow-up: \(record.title)")
                .accessibilityIdentifier("follow-up-edit-\(record.id)")

                FlowLayout(spacing: Tokens.Space.s2) {
                    Label(directionText, systemImage: record.direction == .waitingFor ? "person.crop.circle.badge.clock" : "person.crop.circle")
                    Text(accountName)
                    if !isOpen { Text(record.status == .completed ? "Completed" : "Dismissed") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let dueAt = record.dueAt {
                    Label(deadlineLabel(dueAt), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(isOpen && FollowUpSchedule.isOverdue(dueAt, now: now) ? Tokens.Status.warning : Color.secondary)
                }

                ForEach(entry.reminders, id: \.kind) { reminder in
                    reminderStatus(reminder)
                }

                Button(action: onOpenSource) {
                    Label(record.sourceSubject.isEmpty ? "Open source email" : record.sourceSubject, systemImage: "envelope")
                        .font(.caption)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open source email")
                .accessibilityLabel("Open source email: \(record.sourceSubject)")
                .accessibilityIdentifier("follow-up-source-\(record.id)")
            }
            .padding(.vertical, Tokens.Space.s1_5)

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
            .help("Follow-up actions")
            .accessibilityLabel("Actions for \(record.title)")
            .accessibilityIdentifier("follow-up-actions-\(record.id)")
        }
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("follow-up-row-\(record.id)")
        .contextMenu { actions.disabled(isBusy) }
    }

    @ViewBuilder private var actions: some View {
        Button("Edit…", systemImage: "pencil", action: onEdit)
        Button("Open Email", systemImage: "envelope", action: onOpenSource)
        if isOpen {
            Button("Draft Follow-up", systemImage: "square.and.pencil", action: onDraft)
            if entry.reminders.contains(where: { $0.receivedReplyMessageID == nil }) {
                Menu("Remind Me") {
                    Button("Tomorrow Morning") { onSnooze(FollowUpSchedule.tomorrow(from: now)) }
                    Button("Friday Morning") { onSnooze(FollowUpSchedule.friday(from: now)) }
                    Button("Choose Date…", action: onEdit)
                }
            }
            Divider()
            Button("Complete", systemImage: "checkmark.circle", action: onComplete)
            Button("Dismiss", systemImage: "minus.circle", action: onDismiss)
        } else {
            Button("Reopen", systemImage: "arrow.uturn.backward", action: onReopen)
        }
    }

    @ViewBuilder private func reminderStatus(_ reminder: CommitmentReminderRecord) -> some View {
        if reminder.receivedReplyMessageID != nil {
            Label(isOpen ? "Reply received · commitment still open" : "Reply received", systemImage: "arrowshape.turn.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isOpen {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                let condition = reminder.kind == .noReply ? "if nobody replies" : "while unresolved"
                Label("\(reminder.remindAt.formatted(date: .abbreviated, time: .shortened)) · \(condition)", systemImage: "bell")
                    .font(.caption)
                    .foregroundStyle(reminder.remindAt <= now ? Tokens.Status.warning : Color.secondary)
                if reminder.kind == .noReply && reminder.remindAt <= now {
                    replyCheck
                } else if reminder.deliveredAt != nil {
                    Text("Reminder delivered").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var replyCheck: some View {
        switch checkState {
        case .checking:
            HStack(spacing: Tokens.Space.s1) {
                ProgressView().controlSize(.mini)
                Text("Checking for replies…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .checked(let date):
            Text("Replies checked \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            Label("Couldn’t check for replies. Refresh to try again.", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case nil:
            Text("Replies haven’t been checked yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var completionSymbol: String {
        switch record.status {
        case .open: "circle"
        case .completed: "checkmark.circle.fill"
        case .dismissed: "minus.circle"
        }
    }

    private func deadlineLabel(_ date: Date) -> String {
        let formatted = FollowUpSchedule.deadlineText(date)
        guard isOpen else { return "Due \(formatted)" }
        if FollowUpSchedule.isOverdue(date, now: now) { return "Overdue · \(formatted)" }
        if FollowUpSchedule.isDueToday(date, now: now) { return "Due today" }
        return "Due \(formatted)"
    }

    private var directionText: String {
        let person = [record.ownerName, record.ownerEmail].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if record.direction == .waitingFor { return person.map { "Waiting for \($0)" } ?? "Waiting for someone" }
        return person.map { "I owe · \($0)" } ?? "I owe"
    }
}

enum FollowUpSchedule {
    /// A deadline is a calendar day encoded as Gregorian midnight UTC, not an
    /// instant. Reminder dates remain instants. Convert only at picker/display
    /// boundaries so changing time zones never changes the saved deadline day.
    static func canonicalDeadline(_ date: Date, calendar: Calendar = .current) -> Date {
        let local = deadlineCalendar(timeZone: calendar.timeZone)
        let components = local.dateComponents([.year, .month, .day], from: date)
        let utc = deadlineCalendar(timeZone: .gmt)
        return utc.date(from: components) ?? utc.startOfDay(for: date)
    }

    static func pickerDate(from canonical: Date, calendar: Calendar = .current) -> Date {
        let utc = deadlineCalendar(timeZone: .gmt)
        let components = utc.dateComponents([.year, .month, .day], from: canonical)
        let local = deadlineCalendar(timeZone: calendar.timeZone)
        return local.date(from: components) ?? local.startOfDay(for: canonical)
    }

    static func deadlineText(_ canonical: Date, locale: Locale = .current) -> String {
        canonical.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
            calendar: deadlineCalendar(timeZone: .gmt), timeZone: .gmt))
    }

    static func isOverdue(_ dueAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        deadlineCalendar(timeZone: .gmt).startOfDay(for: dueAt) < canonicalDeadline(now, calendar: calendar)
    }

    static func isDueToday(_ dueAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        deadlineCalendar(timeZone: .gmt).startOfDay(for: dueAt) == canonicalDeadline(now, calendar: calendar)
    }

    private static func deadlineCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func tomorrow(from date: Date, calendar: Calendar = .current) -> Date {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(24 * 60 * 60)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay) ?? nextDay
    }

    static func friday(from date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(hour: 9, minute: 0, second: 0, weekday: 6),
                          matchingPolicy: .nextTime) ?? tomorrow(from: date, calendar: calendar)
    }
}
