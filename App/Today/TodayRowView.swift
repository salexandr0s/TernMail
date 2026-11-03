import MailStore
import SwiftUI

struct TodayRowView: View {
    let row: TodayRow
    let accountName: String
    let checkState: FollowUpReplyCheckState?
    let now: Date
    let isBusy: Bool
    let onEdit: () -> Void
    let onComplete: () -> Void
    let onDismiss: () -> Void
    let onReopen: () -> Void
    let onDefer: (Date) -> Void
    let onChooseDate: () -> Void
    let onBringBack: () -> Void
    let onOpenSource: () -> Void
    let onDraft: () -> Void

    private var record: CommitmentRecord { row.entry.record }
    private var isOpen: Bool { record.status == .open }
    private var isDeferred: Bool { isOpen && (record.deferredUntil.map { $0 > now } ?? false) }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Button(action: isOpen ? onComplete : onReopen) {
                Group {
                    if isBusy { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: completionSymbol).font(.title2.weight(.light))
                            .foregroundStyle(record.status == .completed ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(isBusy)
            .help(isOpen ? "Complete follow-up" : "Reopen follow-up")
            .accessibilityLabel("\(isOpen ? "Complete" : "Reopen"): \(record.title)")
            .accessibilityIdentifier("today-status-\(record.id)")

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
                .buttonStyle(.plain).disabled(isBusy)
                .accessibilityLabel("Edit follow-up: \(record.title)")
                .accessibilityIdentifier("today-edit-\(record.id)")

                FlowLayout(spacing: Tokens.Space.s2) {
                    Text(directionText)
                    Text(accountName)
                    if !isOpen { Text(record.status == .completed ? "Completed" : "Dismissed") }
                }
                .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    ForEach(row.reasons) { reason in
                        Label(reason.title, systemImage: reasonSymbol(reason.code))
                            .font(.callout)
                            .foregroundStyle(isUrgent(reason.code) ? Tokens.Status.warning : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("today-reason-\(record.id)-\(reason.id)")
                    }
                }

                if let deferredUntil = record.deferredUntil, isDeferred {
                    Label("Snoozed until \(deferredUntil.formatted(date: .abbreviated, time: .shortened))", systemImage: "moon.zzz")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Bring Back to Today", action: onBringBack)
                        .controlSize(.small).disabled(isBusy)
                        .accessibilityIdentifier("today-bring-back-\(record.id)")
                }
                if let dueAt = record.dueAt {
                    Text("Deadline: \(FollowUpSchedule.deadlineText(dueAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(row.entry.reminders, id: \.kind) { reminder in
                    if isOpen && reminder.receivedReplyMessageID == nil {
                        let condition = reminder.kind == .noReply ? "if nobody replies" : "while unresolved"
                        Text("Reminder: \(reminder.remindAt.formatted(date: .abbreviated, time: .shortened)) · \(condition)")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if isOpen && row.entry.reminders.contains(where: { $0.kind == .noReply && $0.receivedReplyMessageID == nil }) {
                    replyCheck
                }

                Button(action: onOpenSource) {
                    Label(record.sourceSubject.isEmpty ? "Open source email" : record.sourceSubject, systemImage: "envelope")
                        .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Open source email: \(record.sourceSubject)")
                .accessibilityIdentifier("today-source-\(record.id)")

                if isOpen {
                    FlowLayout(spacing: Tokens.Space.s3) {
                        Button("Draft Follow-up", systemImage: "square.and.pencil", action: onDraft)
                            .accessibilityIdentifier("today-draft-\(record.id)")
                        if !isDeferred {
                            Button("Snooze…", systemImage: "moon.zzz", action: onChooseDate)
                                .accessibilityLabel("Snooze \(record.title)")
                                .accessibilityIdentifier("today-snooze-\(record.id)")
                        }
                    }
                    .controlSize(.small).disabled(isBusy)
                }
            }
            .padding(.vertical, Tokens.Space.s1_5)

            Menu { actions } label: {
                Image(systemName: "ellipsis")
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(isBusy)
            .accessibilityLabel("Actions for \(record.title)")
            .accessibilityIdentifier("today-actions-\(record.id)")
        }
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-row-\(record.id)")
        .contextMenu { actions.disabled(isBusy) }
    }

    @ViewBuilder private var actions: some View {
        Button("Edit…", systemImage: "pencil", action: onEdit)
        Button("Open Email", systemImage: "envelope", action: onOpenSource)
        if isOpen {
            Button("Draft Follow-up", systemImage: "square.and.pencil", action: onDraft)
            if isDeferred { Button("Bring Back to Today", systemImage: "sun.max", action: onBringBack) }
            else { Menu("Snooze", systemImage: "moon.zzz") { snoozeActions } }
            Divider()
            Button("Complete", systemImage: "checkmark.circle", action: onComplete)
            Button("Dismiss", systemImage: "minus.circle", action: onDismiss)
                .accessibilityIdentifier("today-dismiss-\(record.id)")
        } else {
            Button("Reopen", systemImage: "arrow.uturn.backward", action: onReopen)
        }
    }

    @ViewBuilder private var snoozeActions: some View {
        let tomorrow = FollowUpSchedule.tomorrow(from: now)
        let friday = FollowUpSchedule.friday(from: now)
        Button("Tomorrow · \(tomorrow.formatted(date: .abbreviated, time: .shortened))") { onDefer(tomorrow) }
            .accessibilityIdentifier("today-snooze-tomorrow-\(record.id)")
        Button("Friday · \(friday.formatted(date: .abbreviated, time: .shortened))") { onDefer(friday) }
        Button("Choose Date…", action: onChooseDate)
    }

    @ViewBuilder private var replyCheck: some View {
        switch checkState {
        case .checking: Text("Checking for replies…").font(.caption).foregroundStyle(.secondary)
        case .checked(let checkedAt):
            Text("Replies checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            Text("Couldn’t check for replies. Refresh to try again.").font(.caption).foregroundStyle(.secondary)
        case nil: Text("Replies haven’t been checked yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var completionSymbol: String {
        switch record.status {
        case .open: "circle"
        case .completed: "checkmark.circle.fill"
        case .dismissed: "minus.circle"
        }
    }

    private var directionText: String {
        let person = [record.ownerName, record.ownerEmail].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if record.direction == .waitingFor { return person.map { "Waiting for \($0)" } ?? "Waiting for someone" }
        return person.map { "I owe · \($0)" } ?? "I owe"
    }

    private func isUrgent(_ reason: TodayReasonCode) -> Bool {
        reason == .overdue || reason == .dueToday || reason == .reminderDue
    }

    private func reasonSymbol(_ reason: TodayReasonCode) -> String {
        switch reason {
        case .overdue, .dueToday, .dueSoon, .deadlineChanged: "calendar"
        case .reminderDue, .reminderChanged: "bell"
        case .owedByMe: "person.crop.circle"
        case .waitingFor: "person.crop.circle.badge.clock"
        case .replyReceived: "arrowshape.turn.up.left"
        case .replyUnknown: "questionmark.circle"
        case .newlyTracked: "plus.circle"
        case .completed: "checkmark.circle"
        case .dismissed: "minus.circle"
        case .reopened, .returned: "arrow.uturn.backward"
        case .deferred: "moon.zzz"
        case .detailsChanged: "pencil"
        }
    }
}
