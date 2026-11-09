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
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Bring back").font(.headline)
                    DatePicker("Bring back", selection: $until, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field).labelsHidden()
                        .accessibilityLabel("Bring back date and time")
                        .accessibilityIdentifier("today-snooze-date")
                    Label(timeZoneName, systemImage: "globe")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Time zone: \(timeZoneName)")
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Quick choices").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: Tokens.Space.s2) {
                        preset("Tomorrow", date: FollowUpSchedule.tomorrow(from: .now), identifier: "tomorrow")
                        preset("Friday", date: FollowUpSchedule.friday(from: .now), identifier: "friday")
                    }
                }
                Text("Deadlines and reminder settings stay unchanged. Reminders pause until the follow-up returns to Today.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Label {
                        Text(errorMessage).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Tokens.Status.error)
                    }
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Space.s5).padding(.bottom, Tokens.Space.s5).disabled(isSaving)
            PopupFooter {
                if isSaving {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving snooze")
                    Text("Snoozing…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                    .accessibilityIdentifier("today-snooze-cancel")
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
        .onChange(of: until) { _, _ in errorMessage = nil }
    }

    private var timeZoneName: String {
        TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier
    }

    private func preset(_ title: String, date: Date, identifier: String) -> some View {
        Button {
            until = date
        } label: {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.callout.weight(.medium))
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Space.s1)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(title), \(date.formatted(date: .complete, time: .shortened))")
        .accessibilityIdentifier("today-snooze-preset-\(identifier)")
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
