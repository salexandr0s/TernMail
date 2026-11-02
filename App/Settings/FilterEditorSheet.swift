import GmailAPI
import SwiftUI

struct FilterEditorSheet: View {
    @Bindable var model: SettingsModel
    let original: GmailFilter?
    @State private var draft: FilterEditorDraft
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fromFocused: Bool

    init(model: SettingsModel, original: GmailFilter?, initialCriteria: GmailFilter.Criteria? = nil) {
        self.model = model
        self.original = original
        let initial = original ?? initialCriteria.map { GmailFilter(criteria: $0, action: .init()) }
        _draft = State(initialValue: FilterEditorDraft(filter: initial, labels: model.labels))
    }

    var body: some View {
        SettingsEditorSheet(
            title: original == nil ? "New Filter" : "Edit Filter",
            width: Tokens.Settings.editorWideWidth,
            messages: [validation, model.error].compactMap { $0 },
            scrolls: false
        ) {
            Form {
                criteriaSection
                deliverySection
                actionsSection
                forwardingSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipped()
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            if model.isSaving { ProgressView().controlSize(.small) }
            Button("Save Filter") {
                let filter = draft.filter()
                Task { if await model.saveFilter(filter, replacing: original) { dismiss() } }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canEdit || validation != nil)
        }
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { fromFocused = true }
    }

    private var criteriaSection: some View {
        Section {
            TextField("From", text: $draft.from)
                .focused($fromFocused)
            TextField("To", text: $draft.to)
            TextField("Subject", text: $draft.subject)
            TextField("Has the words", text: $draft.query)
            TextField("Doesn't have", text: $draft.negatedQuery)
            LabeledContent("Size") {
                HStack(spacing: Tokens.Space.s2) {
                    Picker("Size comparison", selection: $draft.sizeComparison) {
                        Text("Larger than").tag(GmailFilter.SizeComparison.larger)
                        Text("Smaller than").tag(GmailFilter.SizeComparison.smaller)
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Bytes", text: $draft.sizeText)
                        .accessibilityLabel("Size in bytes")
                }
            }
            Toggle("Has attachment", isOn: $draft.hasAttachment)
            Toggle("Exclude chats", isOn: $draft.excludeChats)
        } header: {
            Text("Match incoming messages")
        } footer: {
            Text("Leave a field empty to ignore it.")
        }
    }

    private var deliverySection: some View {
        Section("Delivery") {
            Toggle("Skip the Inbox", isOn: $draft.skipInbox)
            Toggle("Move to Trash", isOn: $draft.trash)
            Toggle("Never send to Spam", isOn: $draft.neverSpam)
        }
    }

    private var actionsSection: some View {
        Section("Organize matching mail") {
            Toggle("Mark as read", isOn: $draft.markRead)
            Toggle("Star", isOn: $draft.star)
            SettingsControlRow("Importance") {
                Picker("Importance", selection: $draft.importance) {
                    Text("Leave unchanged").tag(0)
                    Text("Always important").tag(1)
                    Text("Never important").tag(-1)
                }
                .frame(maxWidth: Tokens.Settings.pickerWidth)
            }
            SettingsControlRow("Apply label") {
                Picker("Apply label", selection: $draft.labelID) {
                    Text("None").tag("")
                    ForEach(model.labels.filter { !$0.isSystem }, id: \.id) { label in
                        Text(label.name).tag(label.id)
                    }
                }
                .frame(maxWidth: Tokens.Settings.pickerWidth)
            }
        }
    }

    private var forwardingSection: some View {
        Section {
            SettingsControlRow("Forward to") {
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
                .frame(maxWidth: Tokens.Settings.pickerWidth)
                .help(draft.forward)
            }
        } header: {
            Text("Forwarding")
        } footer: {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Add and verify forwarding addresses in Gmail before using them here.")
                if !draft.preservedAdds.isEmpty || !draft.preservedRemoves.isEmpty {
                    Text("Other Gmail actions will be kept: \((draft.preservedAdds.map { "Add " + $0 } + draft.preservedRemoves.map { "Remove " + $0 }).joined(separator: ", "))")
                }
            }
        }
    }

    private var validation: String? { draft.validation(acceptedForwarding: model.forwarding.filter(\.isAccepted).map(\.forwardingEmail)) }
}
