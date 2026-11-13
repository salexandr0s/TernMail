import MailStore
import SwiftUI

struct TodayRowView: View {
    let row: TodayRow
    let accountName: String
    let checkState: FollowUpReplyCheckState?
    let snooze: TodaySnoozeChoices
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
    @State private var showsDetails = false

    private var record: CommitmentRecord { row.entry.record }
    private var isOpen: Bool { record.status == .open }

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

            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                Button(action: onEdit) {
                    Text(record.title)
                        .font(.callout.weight(isOpen ? .semibold : .regular))
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

                Text("\(directionText) · \(accountName)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("today-reason-\(record.id)-\(record.direction == .waitingFor ? "waitingFor" : "owedByMe")")

                FlowLayout(spacing: Tokens.Space.s2) {
                    ForEach(visibleReasons) { reason in
                        Label {
                            Text(reasonSummary(reason))
                                .foregroundStyle(isUrgent(reason.code) ? Color.primary : Color.secondary)
                        } icon: {
                            Image(systemName: reasonSymbol(reason.code))
                                .foregroundStyle(isUrgent(reason.code) ? Tokens.Status.warning : Color.secondary)
                        }
                            .font(.caption.weight(isUrgent(reason.code) ? .medium : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                            .help(reason.title)
                            .accessibilityLabel(reason.title)
                            .accessibilityIdentifier("today-reason-\(record.id)-\(reason.id)")
                    }
                    if !isOpen && !row.reasons.contains(where: { $0.code == .completed || $0.code == .dismissed }) {
                        Text(record.status == .completed ? "Completed" : "Dismissed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let deferredUntil = record.deferredUntil, row.isSnoozed {
                    Label("Snoozed until \(deferredUntil.formatted(date: .abbreviated, time: .shortened))", systemImage: "moon.zzz")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if checksReplies { replyCheck }

                Button(action: onOpenSource) {
                    Label(record.sourceSubject.isEmpty ? "Open source email" : record.sourceSubject, systemImage: "envelope")
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(record.sourceSubject.isEmpty ? "Open source email" : record.sourceSubject)
                .accessibilityLabel("Open source email: \(record.sourceSubject)")
                .accessibilityIdentifier("today-source-\(record.id)")

                if hasScheduleDetails {
                    DisclosureGroup("Details", isExpanded: $showsDetails) {
                        scheduleDetails.padding(.top, Tokens.Space.s1)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Schedule and reply details for \(record.title)")
                    .accessibilityIdentifier("today-details-\(record.id)")
                }
                if isOpen {
                    FlowLayout(spacing: Tokens.Space.s2) {
                        Button("Draft Follow-up", systemImage: "square.and.pencil", action: onDraft)
                            .accessibilityIdentifier("today-draft-\(record.id)")
                        if row.isSnoozed {
                            Button("Bring Back to Today", systemImage: "sun.max", action: onBringBack)
                                .accessibilityIdentifier("today-bring-back-\(record.id)")
                        } else {
                            Button("Snooze…", systemImage: "moon.zzz", action: onChooseDate)
                                .accessibilityLabel("Snooze \(record.title)")
                                .accessibilityIdentifier("today-snooze-\(record.id)")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(isBusy)
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
            if row.isSnoozed { Button("Bring Back to Today", systemImage: "sun.max", action: onBringBack) }
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
        let tomorrow = snooze.tomorrow, friday = snooze.friday
        Button("Tomorrow · \(tomorrow.formatted(date: .abbreviated, time: .shortened))") { onDefer(tomorrow) }
            .accessibilityIdentifier("today-snooze-tomorrow-\(record.id)")
        Button("Friday · \(friday.formatted(date: .abbreviated, time: .shortened))") { onDefer(friday) }
        Button("Choose Date…", action: onChooseDate)
    }

    private var replyCheck: some View {
        Group {
            switch checkState {
            case .checking: Label("Checking for replies…", systemImage: "arrow.trianglehead.2.clockwise")
            case .checked: Label("No reply at last check", systemImage: "checkmark")
            case .unavailable: Label("Reply status unavailable. Refresh to try again.", systemImage: "questionmark.circle")
            case nil: Label("Replies haven't been checked yet.", systemImage: "questionmark.circle")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("today-reason-\(record.id)-replyUnknown")
    }

    private var checksReplies: Bool {
        isOpen && row.entry.reminders.contains { $0.kind == .noReply && $0.receivedReplyMessageID == nil }
    }

    private var hasScheduleDetails: Bool {
        record.dueAt != nil || (isOpen && row.entry.reminders.contains { $0.receivedReplyMessageID == nil })
    }

    private var scheduleDetails: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            if let dueAt = record.dueAt {
                Text("Deadline: \(FollowUpSchedule.deadlineText(dueAt))")
            }
            ForEach(row.entry.reminders, id: \.kind) { reminder in
                if isOpen && reminder.receivedReplyMessageID == nil {
                    let condition = reminder.kind == .noReply ? "if nobody replies" : "while unresolved"
                    Text("Reminder: \(reminder.remindAt.formatted(date: .abbreviated, time: .shortened)) · \(condition)")
                }
            }
            if checksReplies, case .checked(let checkedAt) = checkState {
                Text("Replies checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private var visibleReasons: [TodayReason] {
        let reasons = row.reasons.filter {
            $0.code != .waitingFor && $0.code != .owedByMe && !(checksReplies && $0.code == .replyUnknown)
        }
        let priority: [TodayReasonCode] = [.overdue, .dueToday, .reminderDue, .replyReceived, .dueSoon]
        guard let primary = priority.compactMap({ code in reasons.first { $0.code == code } }).first else { return reasons }
        return [primary] + reasons.filter { $0.id != primary.id }
    }

    private func reasonSummary(_ reason: TodayReason) -> String {
        switch reason.code {
        case .newlyTracked: "New since last visit"
        case .deadlineChanged: "Deadline changed"
        case .detailsChanged: "Details changed"
        case .completed: "Completed since last visit"
        case .dismissed: "Dismissed since last visit"
        case .reopened: "Reopened since last visit"
        case .reminderChanged: "Reminder changed"
        case .returned: "Brought back since last visit"
        default: reason.title
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
