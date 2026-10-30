import GmailAPI
import SwiftUI

struct FilterEditorSheet: View {
    @Bindable var model: SettingsModel
    let original: GmailFilter?
    @State private var draft: FilterEditorDraft
    @Environment(\.dismiss) private var dismiss

    init(model: SettingsModel, original: GmailFilter?, initialCriteria: GmailFilter.Criteria? = nil) {
        self.model = model
        self.original = original
        let initial = original ?? initialCriteria.map { GmailFilter(criteria: $0, action: .init()) }
        _draft = State(initialValue: FilterEditorDraft(filter: initial, labels: model.labels))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text(original == nil ? "New Filter" : "Edit Filter").font(.title2.weight(.semibold))
            ScrollView {
                Form {
                    Section("Match incoming messages") {
                        textField("From", text: $draft.criteria.from)
                        textField("To", text: $draft.criteria.to)
                        textField("Subject", text: $draft.criteria.subject)
                        textField("Has the words", text: $draft.criteria.query)
                        textField("Doesn't have", text: $draft.criteria.negatedQuery)
                        Toggle("Has attachment", isOn: bool($draft.criteria.hasAttachment))
                        Toggle("Exclude chats", isOn: bool($draft.criteria.excludeChats))
                        HStack {
                            Picker("Size", selection: Binding(get: { draft.criteria.sizeComparison ?? .larger }, set: { draft.criteria.sizeComparison = $0 })) {
                                Text("Larger than").tag(GmailFilter.SizeComparison.larger)
                                Text("Smaller than").tag(GmailFilter.SizeComparison.smaller)
                            }
                            TextField("Bytes", text: $draft.sizeText).accessibilityLabel("Size in bytes")
                        }
                    }
                    Section("Then") {
                        Toggle("Skip the Inbox", isOn: $draft.skipInbox)
                        Toggle("Mark as read", isOn: $draft.markRead)
                        Toggle("Star", isOn: $draft.star)
                        Toggle("Never send to Spam", isOn: $draft.neverSpam)
                        Toggle("Move to Trash", isOn: $draft.trash)
                        Picker("Importance", selection: $draft.importance) {
                            Text("Leave unchanged").tag(0)
                            Text("Always important").tag(1)
                            Text("Never important").tag(-1)
                        }
                        Picker("Apply label", selection: $draft.labelID) {
                            Text("None").tag("")
                            ForEach(model.labels.filter { !$0.isSystem }, id: \.id) { label in
                                Text(label.name).tag(label.id)
                            }
                        }
                        Picker("Forward to", selection: $draft.forward) {
                            Text("No forwarding").tag("")
                            ForEach(model.forwarding, id: \.forwardingEmail) { address in
                                Text(address.forwardingEmail + (address.isAccepted ? "" : " (waiting for verification)"))
                                    .tag(address.forwardingEmail).disabled(!address.isAccepted)
                            }
                            if !draft.forward.isEmpty, !model.forwarding.contains(where: { $0.forwardingEmail == draft.forward }) {
                                Text(draft.forward + " (unavailable)").tag(draft.forward).disabled(true)
                            }
                        }
                        Text("Add and verify forwarding addresses in Gmail before using them here.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !draft.preservedAdds.isEmpty || !draft.preservedRemoves.isEmpty {
                            Text("Other Gmail actions will be kept: \((draft.preservedAdds.map { "Add " + $0 } + draft.preservedRemoves.map { "Remove " + $0 }).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Filter") {
                    let filter = draft.filter()
                    Task { if await model.saveFilter(filter, replacing: original) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canEdit || validation != nil)
            }
        }
        .padding(Tokens.Space.s4)
        .frame(width: Tokens.Layout.settingsWidth, height: Tokens.Assistant.settingsHeight)
        .interactiveDismissDisabled(model.isSaving)
    }

    private var validation: String? { draft.validation(acceptedForwarding: model.forwarding.filter(\.isAccepted).map(\.forwardingEmail)) }
    private func textField(_ title: String, text: Binding<String?>) -> some View {
        TextField(title, text: Binding(get: { text.wrappedValue ?? "" }, set: { text.wrappedValue = $0.isEmpty ? nil : $0 }))
    }
    private func bool(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue == true }, set: { binding.wrappedValue = $0 ? true : nil })
    }
}
