import Foundation
import MailStore

enum TodayFilter: String, CaseIterable, Identifiable {
    case briefing, snoozed
    var id: String { rawValue }
    var title: String { self == .briefing ? "Briefing" : "Snoozed" }
}

enum TodaySectionKind: String, CaseIterable, Identifiable {
    case attention, upcoming, waiting, changes, snoozed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: "Needs attention"
        case .upcoming: "Coming up"
        case .waiting: "Waiting for"
        case .changes: "Since your last visit"
        case .snoozed: "Snoozed"
        }
    }
}

enum TodayReasonCode: String {
    case overdue, dueToday, dueSoon, reminderDue, owedByMe, waitingFor, replyReceived, replyUnknown
    case newlyTracked, deadlineChanged, detailsChanged, completed, dismissed, reopened, reminderChanged, deferred, returned
}

struct TodayReason: Identifiable, Equatable {
    let code: TodayReasonCode
    let title: String
    var id: String { code.rawValue }
}

struct TodayRow: Identifiable, Equatable {
    let entry: CommitmentEntry
    let snapshot: TodayCommitmentSnapshot
    let reasons: [TodayReason]
    /// Whether the row is open and hidden from the briefing until a later time.
    let isSnoozed: Bool
    var id: String { entry.id }
}

struct TodaySection: Identifiable, Equatable {
    let kind: TodaySectionKind
    let rows: [TodayRow]
    var id: String { kind.rawValue }
    var title: String { kind.title }
}

/// A read-only projection of the canonical follow-ups and a fixed visit baseline.
struct TodayProjection: Equatable {
    let sections: [TodaySection]
    var rows: [TodayRow] { sections.flatMap(\.rows) }
    var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } }

    static func make(entries: [CommitmentEntry], accountIDs: Set<String>, baseline: TodayVisitBaseline?,
                     replyChecks: [String: FollowUpReplyCheckState] = [:], filter: TodayFilter = .briefing,
                     searchText: String = "", now: Date, calendar: Calendar = .current) -> TodayProjection {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Each row carries its sort key, worked out once when the row is built.
        var grouped: [TodaySectionKind: [(key: (Int, Date, String), row: TodayRow)]] = [:]
        for entry in entries where accountIDs.contains(entry.record.accountID) {
            let record = entry.record
            let isDeferred = record.status == .open && (record.deferredUntil.map { $0 > now } ?? false)
            guard (filter == .snoozed) == isDeferred else { continue }
            guard query.isEmpty || [record.title, record.ownerName ?? "", record.ownerEmail ?? "", record.sourceSubject]
                .contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { continue }
            let snapshot = TodayCommitmentSnapshot(entry: entry)
            var reasons = changes(snapshot, baseline: baseline)
            let day = record.dueAt.map { FollowUpSchedule.pickerDate(from: $0, calendar: calendar) }
            let dayOffset = day.flatMap { calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                                  to: calendar.startOfDay(for: $0)).day }
            let dueReminder = entry.reminders.contains { $0.receivedReplyMessageID == nil && $0.remindAt <= now }
            let kind: TodaySectionKind
            if let deferredUntil = record.deferredUntil, isDeferred {
                kind = .snoozed
                add(.deferred, "Snoozed until \(deferredUntil.formatted(date: .abbreviated, time: .shortened))", to: &reasons)
            } else if record.status == .open {
                if let dayOffset {
                    if dayOffset < 0 { add(.overdue, "Deadline overdue", to: &reasons) }
                    else if dayOffset == 0 { add(.dueToday, "Due today", to: &reasons) }
                    else if dayOffset <= 7, let dueAt = record.dueAt {
                        add(.dueSoon, dayOffset == 1 ? "Due tomorrow" : "Due \(FollowUpSchedule.deadlineText(dueAt))", to: &reasons)
                    }
                }
                if dueReminder { add(.reminderDue, "Reminder due", to: &reasons) }
                let person = record.ownerName ?? record.ownerEmail
                if record.direction == .owedByMe {
                    add(.owedByMe, person.map { "You owe \($0) a response or action" } ?? "You owe a response or action", to: &reasons)
                } else {
                    add(.waitingFor, person.map { "Waiting for \($0)" } ?? "Waiting for someone else", to: &reasons)
                    if let reminder = entry.reminders.first(where: { $0.kind == .noReply }) {
                        if reminder.receivedReplyMessageID != nil {
                            add(.replyReceived, "Reply received; follow-up still open", to: &reasons)
                        } else if case .checked(let checkedAt) = replyChecks[entry.id] {
                            add(.replyUnknown, "No reply as of \(checkedAt.formatted(date: .abbreviated, time: .shortened))", to: &reasons)
                        } else {
                            add(.replyUnknown, "Reply status unavailable", to: &reasons)
                        }
                    }
                }
                if (dayOffset.map { $0 <= 0 } ?? false) || dueReminder || record.direction == .owedByMe { kind = .attention }
                else if dayOffset.map({ (1...7).contains($0) }) ?? false { kind = .upcoming }
                else { kind = .waiting }
            } else {
                guard !reasons.isEmpty else { continue }
                kind = .changes
            }
            let row = TodayRow(entry: entry, snapshot: snapshot, reasons: reasons, isSnoozed: isDeferred)
            grouped[kind, default: []].append((sortKey(row, deadline: day, now: now), row))
        }
        return TodayProjection(sections: TodaySectionKind.allCases.compactMap { kind in
            guard let values = grouped[kind], !values.isEmpty else { return nil }
            return TodaySection(kind: kind, rows: values.sorted { $0.key < $1.key }.map(\.row))
        })
    }

    /// `deadline` is the row's due day in the user's calendar, which its section already needed.
    private static func sortKey(_ row: TodayRow, deadline: Date?, now: Date) -> (Int, Date, String) {
        let reminder = row.entry.reminders.filter { $0.receivedReplyMessageID == nil }.map(\.remindAt).min()
        let priority = row.reasons.contains { $0.code == .overdue } ? 0
            : row.reasons.contains { $0.code == .dueToday || $0.code == .reminderDue } ? 1 : 2
        let activeDeferral = row.entry.record.deferredUntil.flatMap { $0 > now ? $0 : nil }
        return (priority, [deadline, reminder, activeDeferral].compactMap { $0 }.min() ?? .distantFuture, row.id)
    }

    private static func changes(_ current: TodayCommitmentSnapshot, baseline: TodayVisitBaseline?) -> [TodayReason] {
        guard let baseline, baseline.initializedAccountIDs.contains(current.accountID) else { return [] }
        guard let previous = baseline.snapshots[current.id] else { return [TodayReason(code: .newlyTracked, title: "Newly tracked since your last visit")] }
        guard current != previous else { return [] }
        var reasons: [TodayReason] = []
        if current.status != previous.status {
            switch current.status {
            case .completed: add(.completed, "Completed since your last visit", to: &reasons)
            case .dismissed: add(.dismissed, "Dismissed since your last visit", to: &reasons)
            case .open: add(.reopened, "Reopened since your last visit", to: &reasons)
            }
        }
        if current.dueAt != previous.dueAt { add(.deadlineChanged, "Deadline changed since your last visit", to: &reasons) }
        if current.title != previous.title || current.ownerName != previous.ownerName || current.ownerEmail != previous.ownerEmail || current.direction != previous.direction {
            add(.detailsChanged, "Follow-up details changed", to: &reasons)
        }
        if current.deferredUntil != previous.deferredUntil {
            add(current.deferredUntil == nil ? .returned : .deferred,
                current.deferredUntil == nil ? "Brought back since your last visit" : "Snooze changed since your last visit", to: &reasons)
        }
        let received = current.reminders.contains { reminder in
            reminder.receivedReplyMessageID != nil && reminder.receivedReplyMessageID != previous.reminders.first { $0.kind == reminder.kind }?.receivedReplyMessageID
        }
        if received { add(.replyReceived, "Reply received since your last visit", to: &reasons) }
        if current.reminders != previous.reminders && !received && current.status == previous.status {
            add(.reminderChanged, "Reminder changed since your last visit", to: &reasons)
        }
        return reasons
    }

    private static func add(_ code: TodayReasonCode, _ title: String, to reasons: inout [TodayReason]) {
        if !reasons.contains(where: { $0.code == code }) { reasons.append(TodayReason(code: code, title: title)) }
    }
}

/// The two preset times a row's Snooze menu offers. They follow the clock, so
/// they are worked out with the list and a row only shows them.
struct TodaySnoozeChoices: Equatable {
    let tomorrow: Date
    let friday: Date

    init(now: Date) {
        tomorrow = FollowUpSchedule.tomorrow(from: now)
        friday = FollowUpSchedule.friday(from: now)
    }
}

/// The follow-up list as the Today page shows it. `TodayModel` prepares it when
/// its inputs change, so drawing the page only reads it.
struct TodayPresentation: Equatable {
    /// Every row in display order. An owed row keeps the place its section gives it.
    let rows: [TodayRow]
    /// `rows` as snapshots. The acknowledgement compares this array on each scroll step.
    let snapshots: [TodayCommitmentSnapshot]
    /// Open commitments the user owes. The briefing lists them under "I owe".
    let owed: [TodayRow]
    /// The follow-up list: each section without its owed rows. A section left empty is dropped.
    let sections: [TodaySection]
    /// Section and row IDs in display order. The list animates when they change.
    let contentIDs: [String]
    let snooze: TodaySnoozeChoices

    var followUpCount: Int { rows.count - owed.count }

    init(projection: TodayProjection, filter: TodayFilter, now: Date) {
        func isOwed(_ row: TodayRow) -> Bool {
            filter == .briefing && row.entry.record.status == .open && row.entry.record.direction == .owedByMe
        }
        rows = projection.rows
        snapshots = rows.map(\.snapshot)
        owed = rows.filter(isOwed)
        sections = projection.sections.compactMap { section in
            let others = section.rows.filter { !isOwed($0) }
            return others.isEmpty ? nil : TodaySection(kind: section.kind, rows: others)
        }
        contentIDs = projection.sections.flatMap { [$0.id] + $0.rows.map(\.id) }
        snooze = TodaySnoozeChoices(now: now)
    }
}
