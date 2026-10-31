import MailStore
import SwiftUI

struct CalendarActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CalendarModel

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
        .frame(minWidth: Tokens.Calendar.activityWidth, idealWidth: Tokens.Calendar.activityWidth, maxWidth: .infinity,
               minHeight: Tokens.Calendar.sheetMinHeight, idealHeight: CalendarSheetLayout.height(Tokens.Calendar.activityHeight), maxHeight: .infinity)
    }

    private func activityRow(_ operation: CalendarOperation) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: symbol(operation.status))
                .font(.title3).foregroundStyle(color(operation.status))
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(operation)).font(.headline).lineLimit(2)
                    Spacer(minLength: Tokens.Space.s2)
                    Text(statusTitle(operation.status)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if let owner = model.calendars.first(where: { $0.accountID == operation.accountID && $0.calendarID == operation.calendarID }) {
                    Text("\(owner.accountName) · \(owner.title)").font(.caption).foregroundStyle(.secondary)
                }
                Text(operation.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
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
                        Button("Review and Retry") {
                            if operation.status == .conflicted { dismiss() }
                            Task { await model.retryOperation(operation) }
                        }
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

    private func title(_ operation: CalendarOperation) -> String {
        switch operation.mutation {
        case .create(let event): "Create \(event.title)"
        case .importEvent(let event): "Import \(event.title)"
        case .importSeries(let master, _): "Import \(master.title)"
        case .update: "Update event"
        case .delete: "Delete event"
        case .respond: "Reply to invitation"
        case .move: "Move event"
        case .splitSeries: "Change following events"
        case .deleteFollowing: "Delete following events"
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
