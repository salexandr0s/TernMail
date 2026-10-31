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
                SettingsToggleRow("Vacation Responder", detail: "Reply automatically while you're away.", isOn: $settings.enableAutoReply)
                TextField("Subject", text: $settings.responseSubject.or(""))
                SettingsMessageEditor(draft: draft, isEditable: model.canEdit)
            }
            Section("Recipients") {
                SettingsToggleRow("Only Reply to Contacts", isOn: $settings.restrictToContacts)
                if model.account?.hostedDomain != nil {
                    SettingsToggleRow("Only Reply Within My Organization", isOn: $settings.restrictToDomain)
                }
            }
            Section("Schedule") {
                dateRows(toggle: "Start Date", picker: "Starts", date: $settings.startTime)
                dateRows(toggle: "End Date", picker: "Ends", date: $settings.endTime)
            }
        }
        .safeAreaInset(edge: .bottom) { saveBar }
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
        HStack(spacing: Tokens.Space.s3) {
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Tokens.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasChanges {
                Text("Unsaved changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isSaving { ProgressView().controlSize(.small) }
            Button("Save Vacation Responder") {
                let edited = editedSettings
                Task {
                    if await model.saveVacation(edited, previous: previous) { previous = edited }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canEdit || validationMessage != nil || !hasChanges)
        }
        .padding(.horizontal, Tokens.Space.s5)
        .padding(.vertical, Tokens.Space.s3)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
