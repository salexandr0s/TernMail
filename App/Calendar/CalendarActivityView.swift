import MailStore
import SwiftUI

struct CalendarActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack {
                Text("Calendar activity").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.operations.isEmpty {
                TernEmptyState(title: "No calendar changes", systemImage: "checkmark.circle", message: "Proposals and saved changes appear here.")
            } else {
                List(model.operations.reversed()) { operation in
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        HStack {
                            Image(systemName: symbol(operation.status)).foregroundStyle(color(operation.status))
                            Text(title(operation)).font(.headline)
                            Spacer()
                            Text(operation.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        if let owner = model.calendars.first(where: { $0.accountID == operation.accountID && $0.calendarID == operation.calendarID }) {
                            Text("\(owner.accountName) · \(owner.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(operation.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        if let error = operation.errorMessage { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                        HStack {
                            switch operation.status {
                            case .proposed:
                                Button("Review proposal") { model.reviewOperation(operation); dismiss() }
                                if operation.attempts == 0 { Button("Dismiss") { Task { await model.cancelOperation(operation) } } }
                            case .queued:
                                Text("Waiting to synchronize").font(.caption).foregroundStyle(.secondary)
                                if operation.attempts == 0 { Button("Cancel") { Task { await model.cancelOperation(operation) } } }
                            case .failed, .conflicted:
                                Button("Review and retry") {
                                    if operation.status == .conflicted { dismiss() }
                                    Task { await model.retryOperation(operation) }
                                }
                            case .running:
                                ProgressView().controlSize(.small)
                            case .completed, .cancelled:
                                EmptyView()
                            }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, Tokens.Space.s2)
                }
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(Tokens.Space.s5).frame(width: 620, height: 500)
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
        case .completed: .green
        case .failed, .conflicted: .orange
        default: .secondary
        }
    }
}
