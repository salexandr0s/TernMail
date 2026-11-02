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
            Section("Automatic reply") {
                SettingsToggleRow("Vacation responder", detail: "Reply automatically while you're away.", isOn: $settings.enableAutoReply)
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
            Section("Schedule") {
                dateRows(toggle: "Start date", picker: "Starts", date: $settings.startTime)
                dateRows(toggle: "End date", picker: "Ends", date: $settings.endTime)
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
            HStack(spacing: Tokens.Space.s3) {
                if hasChanges {
                    Text("Unsaved changes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
