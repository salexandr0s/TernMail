import GmailAPI
import MessageContent
import SwiftUI

/// The responder sends mail, so it keeps an explicit Save and guards unsaved edits.
struct VacationPane: View {
    @Bindable var model: SettingsModel
    let header: GmailSettingsHeader
    @Environment(SettingsUnsavedChanges.self) private var unsaved
    @State private var settings: VacationSettings
    @State private var previous: VacationSettings
    @State private var draft: SettingsMessageDraft

    init(model: SettingsModel, header: GmailSettingsHeader) {
        self.model = model
        self.header = header
        _settings = State(initialValue: model.vacation)
        _previous = State(initialValue: model.vacation)
        _draft = State(initialValue: SettingsMessageDraft(html: model.vacation.responseBodyHtml, plainText: model.vacation.responseBodyPlainText))
    }

    var body: some View {
        SettingsPage {
            header
            Section {
                SettingsToggleRow("Vacation responder", detail: "Send automatic replies during the schedule below.", isOn: $settings.enableAutoReply)
            } header: {
                Text("Automatic reply")
            } footer: {
                Text("Choose Save Changes to update the vacation responder in Gmail.")
            }
            Section {
                dateRows(toggle: "Start date", picker: "Starts", date: $settings.startTime)
                dateRows(toggle: "End date", picker: "Ends", date: $settings.endTime)
            } header: {
                Text("Schedule")
            } footer: {
                Text(scheduleDescription)
            }
            Section("Reply message") {
                TextField("Subject", text: $settings.responseSubject.or(""))
                SettingsMessageEditor(draft: draft, isEditable: model.canEdit)
                    .accessibilityLabel("Vacation reply message")
            }
            Section("Recipients") {
                SettingsToggleRow("Only reply to contacts", isOn: $settings.restrictToContacts)
                if model.account?.hostedDomain != nil {
                    SettingsToggleRow("Only reply within my organization", isOn: $settings.restrictToDomain)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsFooter { saveBar } }
        .onChange(of: model.revision) { _, _ in
            guard !hasChanges else { return }
            settings = model.vacation
            previous = model.vacation
            draft = SettingsMessageDraft(html: model.vacation.responseBodyHtml, plainText: model.vacation.responseBodyPlainText)
        }
        .onChange(of: hasChanges, initial: true) { _, changed in
            if changed { unsaved.set("vacation responder") } else { unsaved.clear() }
        }
        .onDisappear { unsaved.clear() }
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if let validationMessage {
                SettingsErrorLabel(validationMessage)
            }
            if let error = model.error { SettingsErrorLabel(error) }
            HStack(spacing: Tokens.Space.s3) {
                Text(hasChanges ? "Unsaved changes" : "No changes to save")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Tokens.Space.s2)
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Save Changes") {
                    let edited = editedSettings
                    Task {
                        if await model.saveVacation(edited, previous: previous) { previous = edited }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Save vacation responder")
                .disabled(!model.canEdit || validationMessage != nil || !hasChanges)
            }
        }
    }

    @ViewBuilder private func dateRows(toggle: String, picker: String, date: Binding<Date?>) -> some View {
        Toggle(toggle, isOn: date.isPresent(default: .now))
            .toggleStyle(.switch)
        if date.wrappedValue != nil {
            DatePicker(picker, selection: date.or(.now))
        }
    }

    private var hasChanges: Bool { editedSettings != previous }

    private var scheduleDescription: String {
        let start = settings.startTime?.formatted(date: .abbreviated, time: .shortened)
        let end = settings.endTime?.formatted(date: .abbreviated, time: .shortened)
        return switch (start, end) {
        case (.some(let start), .some(let end)): "When enabled, replies run from \(start) to \(end)."
        case (.some(let start), .none): "When enabled, replies start \(start) and continue until you turn them off."
        case (.none, .some(let end)): "When enabled, replies continue until \(end)."
        case (.none, .none): "When enabled, replies continue until you turn the responder off."
        }
    }

    private var editedSettings: VacationSettings {
        var result = settings
        result.responseBodyHtml = draft.savedHTML
        result.responseBodyPlainText = draft.savedPlainText
        return result
    }

    private var validationMessage: String? {
        if let start = settings.startTime, let end = settings.endTime, start >= end { return "End must come after Start." }
        if settings.enableAutoReply, [settings.responseSubject, draft.savedPlainText, draft.savedHTML].allSatisfy({ ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Add a subject or message before turning on the vacation responder."
        }
        return nil
    }
}
