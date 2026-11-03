import MailStore
import SwiftUI

struct TodaySnoozeRequest: Identifiable {
    let entry: CommitmentEntry
    var id: String { entry.id }
}

struct TodaySnoozeEditor: View {
    let request: TodaySnoozeRequest
    let followUps: FollowUpsModel
    @Environment(\.dismiss) private var dismiss
    @State private var until = FollowUpSchedule.tomorrow(from: .now)
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            PopupHeader(title: "Snooze in Today", systemImage: "moon.zzz", subtitle: request.entry.record.title)
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                HStack(spacing: Tokens.Space.s2) {
                    Button("Tomorrow") { until = FollowUpSchedule.tomorrow(from: .now) }
                    Button("Friday") { until = FollowUpSchedule.friday(from: .now) }
                }
                .controlSize(.small)
                DatePicker("Bring back", selection: $until, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .accessibilityIdentifier("today-snooze-date")
                Text("This follow-up returns to Today at the chosen time. Its deadline and reminder settings stay the same; reminders pause until then.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Times use \(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier).")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(Tokens.Status.error).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Tokens.Space.s5).padding(.bottom, Tokens.Space.s4).disabled(isSaving)
            PopupFooter {
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Snooze", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(isSaving || until <= .now)
                    .accessibilityIdentifier("today-snooze-save")
            }
        }
        .frame(width: Tokens.Settings.editorWidth)
        .background(Tokens.Surface.primary)
        .interactiveDismissDisabled(isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-snooze-editor")
    }

    private func save() {
        guard !isSaving, until > .now else { return }
        isSaving = true
        errorMessage = nil
        let submitted = until
        Task {
            await followUps.deferAttention(request.entry, until: submitted)
            if followUps.entries.first(where: { $0.id == request.entry.id })?.record.deferredUntil == submitted {
                dismiss()
            } else {
                errorMessage = followUps.errorMessage ?? "Couldn’t snooze this follow-up. Try again."
            }
            isSaving = false
        }
    }
}
