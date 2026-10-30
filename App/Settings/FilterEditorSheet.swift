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
        SettingsEditorSheet(
            title: original == nil ? "New Filter" : "Edit Filter",
            width: Tokens.Settings.editorWideWidth,
            messages: [validation, model.error].compactMap { $0 }
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                criteriaSection
                Divider()
                actionsSection
            }
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
    }

    private var criteriaSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Match incoming messages")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                textField("From", text: $draft.criteria.from)
                textField("To", text: $draft.criteria.to)
                textField("Subject", text: $draft.criteria.subject)
                textField("Has the words", text: $draft.criteria.query)
                textField("Doesn't have", text: $draft.criteria.negatedQuery)
                HStack(spacing: Tokens.Space.s3) {
                    fieldLabel("Size")
                    HStack(spacing: Tokens.Space.s2) {
                        Picker("Size comparison", selection: Binding(get: { draft.criteria.sizeComparison ?? .larger }, set: { draft.criteria.sizeComparison = $0 })) {
                            Text("Larger than").tag(GmailFilter.SizeComparison.larger)
                            Text("Smaller than").tag(GmailFilter.SizeComparison.smaller)
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("Bytes", text: $draft.sizeText)
                            .accessibilityLabel("Size in bytes")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Tokens.Space.s3) {
                    Color.clear.frame(width: Tokens.Space.s12 * 2, height: 0)
                    HStack(spacing: Tokens.Space.s4) {
                        Toggle("Has attachment", isOn: bool($draft.criteria.hasAttachment))
                        Toggle("Exclude chats", isOn: bool($draft.criteria.excludeChats))
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Then")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: Tokens.Space.s4, verticalSpacing: Tokens.Space.s2) {
                GridRow {
                    Toggle("Skip the Inbox", isOn: $draft.skipInbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Mark as read", isOn: $draft.markRead)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Toggle("Star", isOn: $draft.star)
                    Toggle("Never send to Spam", isOn: $draft.neverSpam)
                }
                GridRow {
                    Toggle("Move to Trash", isOn: $draft.trash)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(spacing: Tokens.Space.s3) {
                    fieldLabel("Importance")
                    Picker("Importance", selection: $draft.importance) {
                        Text("Leave unchanged").tag(0)
                        Text("Always important").tag(1)
                        Text("Never important").tag(-1)
                    }
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                HStack(spacing: Tokens.Space.s3) {
                    fieldLabel("Apply label")
                    Picker("Apply label", selection: $draft.labelID) {
                        Text("None").tag("")
                        ForEach(model.labels.filter { !$0.isSystem }, id: \.id) { label in
                            Text(label.name).tag(label.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Tokens.Space.s3) {
                    fieldLabel("Forward to")
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
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Add and verify forwarding addresses in Gmail before using them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !draft.preservedAdds.isEmpty || !draft.preservedRemoves.isEmpty {
                Text("Other Gmail actions will be kept: \((draft.preservedAdds.map { "Add " + $0 } + draft.preservedRemoves.map { "Remove " + $0 }).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var validation: String? { draft.validation(acceptedForwarding: model.forwarding.filter(\.isAccepted).map(\.forwardingEmail)) }

    private func textField(_ title: String, text: Binding<String?>) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            fieldLabel(title)
            TextField("", text: Binding(get: { text.wrappedValue ?? "" }, set: { text.wrappedValue = $0.isEmpty ? nil : $0 }))
                .accessibilityLabel(title)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: Tokens.Space.s12 * 2, alignment: .trailing)
    }

    private func bool(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue == true }, set: { binding.wrappedValue = $0 ? true : nil })
    }
}
