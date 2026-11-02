import MailStore
import SwiftUI

struct CalendarActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CalendarModel
    @State private var recoveryOperation: CalendarOperation?

    var body: some View {
        VStack(spacing: 0) {
            CalendarSheetHeading(title: "Calendar Activity", subtitle: "Review proposals and follow saved changes.", systemImage: "clock.arrow.circlepath")
            Divider()
            if model.operations.isEmpty {
                TernEmptyState(title: "No Calendar Changes", systemImage: "checkmark.circle", message: "Proposals and saved changes appear here.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.operations.reversed()) { operation in
                    activityRow(operation)
                }.listStyle(.inset)
            }
            Divider()
            VStack(spacing: Tokens.Space.s3) {
                if let error = model.errorMessage { CalendarInlineError(message: error) }
                HStack {
                    Text("^[\(model.operations.count) change](inflect: true)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }.padding(Tokens.Space.s4).background(Tokens.Surface.muted)
        }
        .sheet(item: $recoveryOperation) { operation in
            CalendarRecoveryView(model: model, operation: operation)
        }
        .frame(minWidth: Tokens.Calendar.activityWidth, idealWidth: Tokens.Calendar.activityWidth, maxWidth: .infinity,
               minHeight: Tokens.Calendar.sheetMinHeight, idealHeight: CalendarSheetLayout.height(Tokens.Calendar.activityHeight), maxHeight: .infinity)
    }

    private func activityRow(_ operation: CalendarOperation) -> some View {
        let presentation = CalendarOperationPresentation(operation: operation)
        return HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: symbol(operation.status))
                .font(.title3).foregroundStyle(color(operation.status))
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(presentation.title).font(.headline).lineLimit(2)
                    Spacer(minLength: Tokens.Space.s2)
                    Text(statusTitle(operation.status)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if let owner = model.calendars.first(where: { $0.accountID == operation.accountID && $0.calendarID == operation.calendarID }) {
                    Text("\(owner.accountName) · \(owner.title)").font(.caption).foregroundStyle(.secondary)
                }
                if let event = presentation.event, let start = event.start?.resolvedDate(fallbackTimeZone: model.calendar.timeZone) {
                    Text(CalendarLayout.format(start, style: event.isAllDay
                        ? .dateTime.year().month().day() : .dateTime.year().month().day().hour().minute(), calendar: model.calendar))
                        .font(.callout)
                }
                Text("Requested \(operation.createdAt, format: .dateTime.month().day().hour().minute())")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = operation.errorMessage { CalendarInlineError(message: error) }
                HStack(spacing: Tokens.Space.s3) {
                    switch operation.status {
                    case .proposed:
                        Button("Review Proposal") { model.reviewOperation(operation); dismiss() }
                        if operation.attempts == 0 { Button("Dismiss") { Task { await model.cancelOperation(operation) } } }
                    case .queued:
                        Text("Waiting to synchronize").font(.caption).foregroundStyle(.secondary)
                        if operation.attempts == 0 { Button("Cancel") { Task { await model.cancelOperation(operation) } } }
                    case .failed, .conflicted:
                        Button("Review Change") { recoveryOperation = operation }
                            .accessibilityLabel("Review recovery: \(presentation.title)")
                    case .running:
                        ProgressView().controlSize(.small).accessibilityLabel("Synchronizing change")
                    case .completed, .cancelled:
                        EmptyView()
                    }
                }.buttonStyle(.borderless)
            }
        }.padding(.vertical, Tokens.Space.s3)
    }

    private func statusTitle(_ status: CalendarOperation.Status) -> String {
        switch status {
        case .proposed: "Needs review"
        case .queued: "Queued"
        case .running: "Syncing"
        case .completed: "Saved"
        case .failed: "Failed"
        case .conflicted: "Conflict"
        case .cancelled: "Cancelled"
        }
    }

    private func symbol(_ status: CalendarOperation.Status) -> String {
        switch status {
        case .proposed: "doc.text"
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle"
        case .conflicted, .failed: "exclamationmark.triangle"
        case .cancelled: "minus.circle"
        }
    }
    private func color(_ status: CalendarOperation.Status) -> Color {
        switch status {
        case .completed: Tokens.Status.success
        case .failed, .conflicted: Tokens.Status.warning
        default: .secondary
        }
    }
}
