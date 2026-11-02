import GmailAPI
import MailStore
import SwiftUI
import SyncEngine

struct CalendarRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    let model: CalendarModel
    let operation: CalendarOperation
    @State private var review: CalendarOperationRecovery?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var confirmsChanges = false
    @State private var editingDraft: CalendarEditorDraft?

    var body: some View {
        VStack(spacing: 0) {
            CalendarSheetHeading(title: "Review Calendar Change",
                subtitle: CalendarOperationPresentation(operation: operation).title, systemImage: "arrow.triangle.2.circlepath")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    if let review {
                        if review.isAlreadyApplied {
                            Label(completionTitle, systemImage: "checkmark.circle")
                            Text("Finish Review records the event shown below without sending this request again.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(intent).font(.headline)
                            if review.completedStep > 0 {
                                Text("Part of this request is already saved. Resume keeps that progress and applies only the remaining changes.")
                                    .foregroundStyle(.secondary)
                            }
                            if let requested = CalendarOperationPresentation(operation: requestedOperation).event {
                                CalendarRecoveryEventDetails(title: "Requested event", event: requested, calendar: model.calendar)
                            }
                            if let recurrence = review.plannedRecurrence {
                                Text(review.completedStep > 0 ? "The original series was trimmed to this schedule:" : "The original series will end with this schedule:").font(.callout)
                                CalendarRecurrenceDescription(rules: recurrence,
                                    allDay: review.currentEvents.first?.isAllDay ?? false, calendar: model.calendar)
                            }
                        }
                        ForEach(review.currentEvents) { event in
                            CalendarRecoveryEventDetails(title: event.id == review.currentEvents.first?.id ? "Google's current event" : "Related event in Google",
                                event: event, calendar: model.calendar)
                        }
                        if let blocked = review.blockedReason { CalendarInlineError(message: blocked) }
                        if !review.isAlreadyApplied {
                            Toggle("I reviewed the current events and the remaining changes.", isOn: $confirmsChanges)
                            Text(operation.sendUpdates == "none" ? "Google will not send guest updates for this request." : "Google may notify the guests shown above when these changes are saved.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if isWorking {
                        ProgressView("Loading current events…")
                    }
                    if let errorMessage { CalendarInlineError(message: errorMessage) }
                }.padding(Tokens.Space.s4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }.padding(Tokens.Space.s4)
        }
        .frame(minWidth: Tokens.Calendar.activityWidth, idealWidth: Tokens.Calendar.activityWidth,
            minHeight: Tokens.Calendar.sheetMinHeight, idealHeight: CalendarSheetLayout.height(Tokens.Calendar.activityHeight))
        .task { await load() }
        .onChange(of: model.calendars.contains { $0.accountID == operation.accountID && $0.calendarID == operation.calendarID && $0.canWrite }) { _, available in
            if !available { dismiss() }
        }
        .sheet(item: $editingDraft) { draft in
            CalendarEventEditor(draft: draft, calendars: model.calendars.filter { $0.id == draft.calendarKey }, calendar: model.calendar,
                knownExceptionCount: draft.followingExceptionsCount, additionalRecipients: draft.additionalNotificationRecipients) { edited in
                try await model.save(edited)
                editingDraft = nil
                dismiss()
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
        Button("Refresh Review") { Task { await load() } }.disabled(isWorking)
        if let review {
            if review.canDiscard {
                Button("Cancel Request", role: .destructive) { perform(review, discard: true) }
                    .disabled(isWorking || !confirmsChanges)
                    .help("Stops this request. Changes already made in Google are kept.")
                    .accessibilityLabel("Cancel request: \(CalendarOperationPresentation(operation: operation).title)")
            }
            if review.canEdit {
                Button("Edit Request") {
                    do { editingDraft = try model.recoveryDraft(for: review) }
                    catch { errorMessage = error.localizedDescription }
                }.disabled(isWorking)
            }
            Button(review.isAlreadyApplied ? "Finish Review" : "Resume Change") { perform(review) }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || review.blockedReason != nil || (!review.isAlreadyApplied && !confirmsChanges))
                .accessibilityLabel("\(review.isAlreadyApplied ? "Reconcile saved change" : "Resume reviewed change"): \(CalendarOperationPresentation(operation: operation).title)")
        }
    }

    private var requestedOperation: CalendarOperation {
        var value = operation
        value.resultEvent = nil
        if case .update(let id, _, _) = value.mutation,
           let current = review?.currentEvents.first(where: { $0.id == id }) {
            value.beforeEvent = current
        }
        return value
    }

    private var completionTitle: String {
        switch operation.mutation {
        case .importEvent, .importSeries: "A matching event already exists in Google."
        case .delete, .deleteFollowing: "The requested deletion is already saved in Google."
        default: "Google already saved this change."
        }
    }

    private var intent: String {
        switch operation.mutation {
        case .move(_, let destination, _):
            let name = model.calendars.first { $0.accountID == operation.accountID && $0.calendarID == destination }?.title ?? destination
            return "Move this event to \(name)."
        case .respond(_, let status, _):
            let response = status == "accepted" ? "Yes" : status == "declined" ? "No" : "Maybe"
            return "Reply \(response) to this invitation."
        case .splitSeries: return "End the original series and create the requested following events. Related exceptions listed below will be removed."
        case .deleteFollowing: return "End this series before the selected occurrence. Related exceptions listed below will be removed."
        case .delete: return "Delete the current event shown below."
        case .importSeries: return "Import this series and apply its remaining exceptions."
        case .importEvent: return "Import the requested event."
        case .create: return "Create the requested event."
        case .update: return "Apply the requested edits to the current event shown below."
        }
    }

    private func load() async {
        isWorking = true; errorMessage = nil; confirmsChanges = false; review = nil
        defer { isWorking = false }
        do { review = try await model.recoveryReview(for: operation) }
        catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ review: CalendarOperationRecovery, discard: Bool = false) {
        isWorking = true; errorMessage = nil
        Task {
            defer { isWorking = false }
            do { try await model.recover(review, discard: discard); dismiss() }
            catch { errorMessage = error.localizedDescription; self.review = nil; confirmsChanges = false }
        }
    }
}
