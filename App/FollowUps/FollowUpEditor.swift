import MailStore
import SwiftUI

struct FollowUpEditor: View {
    @Bindable var model: FollowUpsModel
    let request: FollowUpEditorRequest
    @State private var values: FollowUpEditValues
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var titleFocused: Bool

    init(model: FollowUpsModel, request: FollowUpEditorRequest) {
        self.model = model
        self.request = request
        _values = State(initialValue: request.values)
    }

    var body: some View {
        VStack(spacing: 0) {
            PopupHeader(title: request.existing == nil ? "Track follow-up" : "Edit follow-up",
                systemImage: "clock.arrow.circlepath", subtitle: model.accountName(for: request.source.accountID))
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    commitmentFields
                    deadlineFields
                    reminderFields
                    source
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(Tokens.Status.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("follow-up-editor-error")
                    }
                }
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s4)
                .disabled(isSaving)
            }
            .scrollBounceBehavior(.basedOnSize)
            PopupFooter {
                ProgressView().controlSize(.small).accessibilityLabel("Saving follow-up").ternDelayedLoading(isSaving)
                Button("Cancel") { model.cancelEditor() }
                    .keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(request.existing == nil ? "Track" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .accessibilityIdentifier("follow-up-editor-save")
            }
        }
        .frame(width: Tokens.Settings.editorWidth)
        .frame(maxHeight: Tokens.Calendar.editorHeight)
        .background(Tokens.Surface.primary)
        .interactiveDismissDisabled(isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("follow-up-editor")
        .task(id: request.id) { titleFocused = true }
    }

    private var commitmentFields: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            TextField("What needs to happen?", text: $values.title, axis: .vertical)
                .font(.title3.weight(.medium)).textFieldStyle(.plain).lineLimit(2...4)
                .focused($titleFocused)
                .accessibilityLabel("Commitment")
                .accessibilityIdentifier("follow-up-editor-title")
            Picker("Direction", selection: $values.direction) {
                Text("Waiting for").tag(CommitmentDirection.waitingFor)
                Text("I owe").tag(CommitmentDirection.owedByMe)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("Commitment direction")
            .accessibilityIdentifier("follow-up-editor-direction")
            TextField(values.direction == .waitingFor ? "Who are you waiting for?" : "Who is this for?", text: $values.ownerName)
                .accessibilityLabel("Person")
                .accessibilityIdentifier("follow-up-editor-person")
            TextField("Email address (optional)", text: $values.ownerEmail)
                .accessibilityLabel("Person’s email address")
                .accessibilityIdentifier("follow-up-editor-email")
        }
        .padding(Tokens.Space.s4)
        .ternSurface(style: .grouped)
    }

    private var deadlineFields: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Toggle("Deadline", isOn: hasDueDate).toggleStyle(.checkbox)
                .accessibilityIdentifier("follow-up-editor-has-deadline")
            if values.dueAt != nil {
                DatePicker("Due", selection: dueDate, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .accessibilityIdentifier("follow-up-editor-deadline")
            }
        }
        .padding(Tokens.Space.s3)
        .ternSurface(style: .grouped)
    }

    private var reminderFields: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Toggle("Remind me", isOn: hasReminder).toggleStyle(.checkbox)
                .disabled(!canSetReminder)
                .accessibilityIdentifier("follow-up-editor-has-reminder")
            if !canSetReminder {
                Text("Reopen this commitment to add a reminder.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if values.reminderKind != nil {
                Picker("Condition", selection: reminderKind) {
                    Text("If nobody replies").tag(CommitmentReminderKind.noReply)
                    Text("While unresolved").tag(CommitmentReminderKind.unresolved)
                }
                .accessibilityIdentifier("follow-up-editor-reminder-kind")
                DatePicker("When", selection: reminderDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .accessibilityIdentifier("follow-up-editor-reminder-date")
                HStack(spacing: Tokens.Space.s2) {
                    Button("Tomorrow") { values.remindAt = FollowUpSchedule.tomorrow(from: .now) }
                    Button("Friday") { values.remindAt = FollowUpSchedule.friday(from: .now) }
                }
                .controlSize(.small)
                Text(reminderExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Times use \(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier). Tern checks reminders while it is running and when it resumes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.s3)
        .ternSurface(style: .grouped)
    }

    private var source: some View {
        Label {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Source email").font(.caption).foregroundStyle(.secondary)
                Text(request.source.subject.isEmpty ? "No subject" : request.source.subject)
                    .font(.callout).lineLimit(2)
                Text(request.source.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "envelope").foregroundStyle(.secondary)
        }
    }

    private var reminderExplanation: String {
        if values.reminderKind == .noReply {
            return "A new reply stops this reminder. The commitment stays open until you complete or dismiss it."
        }
        return "This reminder stays active until you complete or dismiss the commitment, even if someone replies."
    }

    private var canSave: Bool {
        !isSaving && !values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (values.reminderKind == nil || values.remindAt != nil)
    }

    private var canSetReminder: Bool { request.existing?.record.status == .open || request.existing == nil }

    private var hasDueDate: Binding<Bool> {
        Binding(get: { values.dueAt != nil }, set: {
            values.dueAt = $0 ? FollowUpSchedule.canonicalDeadline(FollowUpSchedule.tomorrow(from: .now)) : nil
        })
    }

    private var dueDate: Binding<Date> {
        Binding(get: {
            values.dueAt.map { FollowUpSchedule.pickerDate(from: $0) } ?? FollowUpSchedule.tomorrow(from: .now)
        }, set: {
            values.dueAt = FollowUpSchedule.canonicalDeadline($0)
        })
    }

    private var hasReminder: Binding<Bool> {
        Binding(get: { values.reminderKind != nil }, set: { enabled in
            values.reminderKind = enabled ? .unresolved : nil
            values.remindAt = enabled ? FollowUpSchedule.tomorrow(from: .now) : nil
        })
    }

    private var reminderKind: Binding<CommitmentReminderKind> {
        Binding(get: { values.reminderKind ?? .unresolved }, set: { values.reminderKind = $0 })
    }

    private var reminderDate: Binding<Date> {
        Binding(get: { values.remindAt ?? FollowUpSchedule.tomorrow(from: .now) }, set: { values.remindAt = $0 })
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        let submitted = values
        Task {
            if !(await model.saveEditor(request, values: submitted)) {
                saveError = model.errorMessage ?? "Couldn’t save this follow-up. Try again."
            }
            isSaving = false
        }
    }
}

private struct FollowUpEditorHost: ViewModifier {
    @Bindable var model: FollowUpsModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { model.pendingEditor }, set: { request in
            if request == nil { model.cancelEditor() }
        })) { request in
            FollowUpEditor(model: model, request: request)
        }
    }
}

extension View {
    /// Install once in the main workspace; detached reader actions reveal that window.
    func followUpEditor(model: FollowUpsModel) -> some View {
        modifier(FollowUpEditorHost(model: model))
    }
}
