import GmailAPI
import SwiftUI

struct VacationPane: View {
    @Bindable var model: SettingsModel
    @State private var settings: VacationSettings
    @State private var previous: VacationSettings
    @State private var draft: SettingsMessageDraft

    init(model: SettingsModel) {
        self.model = model
        _settings = State(initialValue: model.vacation)
        _previous = State(initialValue: model.vacation)
        _draft = State(initialValue: SettingsMessageDraft(html: model.vacation.responseBodyHtml, plainText: model.vacation.responseBodyPlainText))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    SettingsToggleRow("Vacation responder", detail: "Reply automatically while you're away.", isOn: $settings.enableAutoReply)
                        .settingsSurface()
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        HStack(spacing: Tokens.Space.s3) {
                            Text("Subject").font(.body)
                            TextField("Subject", text: Binding(get: { settings.responseSubject ?? "" }, set: { settings.responseSubject = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }
                        SettingsMessageEditor(draft: draft, isEditable: model.canEdit)
                    }
                    SettingsGroup("Recipients and schedule", systemImage: "calendar") {
                        SettingsToggleRow("Only reply to contacts", isOn: $settings.restrictToContacts)
                        if model.account?.hostedDomain != nil {
                            Divider().padding(.horizontal, Tokens.Space.s4)
                            SettingsToggleRow("Only reply within my organization", isOn: $settings.restrictToDomain)
                        }
                        Divider().padding(.horizontal, Tokens.Space.s4)
                        dateField("Start", date: $settings.startTime)
                        Divider().padding(.horizontal, Tokens.Space.s4)
                        dateField("End", date: $settings.endTime)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button("Save Vacation Responder") {
                        let edited = editedSettings
                        Task {
                            if await model.saveVacation(edited, previous: previous) { previous = edited }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canEdit || validationMessage != nil || editedSettings == previous)
                }
            }
        }
        .onChange(of: model.revision) { _, _ in
            if editedSettings == previous {
                settings = model.vacation
                previous = model.vacation
                draft = SettingsMessageDraft(html: model.vacation.responseBodyHtml, plainText: model.vacation.responseBodyPlainText)
            }
        }
    }

    private func dateField(_ title: String, date: Binding<Date?>) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            Toggle("\(title) date", isOn: Binding(get: { date.wrappedValue != nil }, set: { date.wrappedValue = $0 ? .now : nil }))
                .toggleStyle(.checkbox)
            Spacer(minLength: 0)
            if date.wrappedValue != nil {
                DatePicker(title, selection: Binding(get: { date.wrappedValue ?? .now }, set: { date.wrappedValue = $0 }))
                    .labelsHidden()
                    .accessibilityLabel("\(title) date")
            }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
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
