import SwiftUI

struct AssistantWritingStyleSettingsSection: View {
    @Bindable var model: AssistantWritingStyleModel
    /// Turning learning off deletes a learned profile, so the host asks first.
    let confirmTurnOff: (AssistantWritingStyleEntry) -> Void

    var body: some View {
        SettingsGroup("Writing style", systemImage: "pencil.line") {
            SettingsNote("Learn how you write from up to 100 recent sent emails in each enabled account. Replies use that account’s style and follow any tone you request.", systemImage: "text.quote")
            ForEach(model.entries) { entry in
                accountRow(entry)
            }
            if model.entries.isEmpty {
                Label("Add a mail account to learn your writing style.", systemImage: "envelope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.storageErrorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            SettingsNote("Excerpts are sent to ChatGPT during setup. Only the learned preferences are saved on this device. Turning learning off deletes the profile.", systemImage: "lock")
        }
    }

    private func accountRow(_ entry: AssistantWritingStyleEntry) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Toggle(isOn: Binding(
                get: { model.isEnabled(entry.id) },
                set: { enabled in
                    if !enabled, entry.learnedAt != nil || entry.isLearning {
                        confirmTurnOff(entry)
                    } else {
                        model.setEnabled(entry.id, enabled: enabled)
                    }
                }
            )) {
                HStack(spacing: Tokens.Space.s3) {
                    AddressAvatar(accountID: entry.id, address: entry.email,
                                  name: entry.displayName ?? "", size: Tokens.Space.s6)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(entry.displayName ?? entry.email)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.displayName ?? entry.email)
                        if entry.displayName != nil {
                            Text(entry.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.email)
                        }
                    }
                }
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Learn writing style for \(entry.email)")
            .accessibilityHint("Turning this off deletes the account’s learned profile.")
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                if entry.isLearning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Learning writing style")
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(entry.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary = entry.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let date = entry.learnedAt {
                        Text("Updated \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if entry.hasLimitedCoverage {
                        Text("Some sent text could not be used or was shortened.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Tokens.Space.s2)
                if entry.isMailAccessEnabled && model.isEnabled(entry.id) {
                    Button("Relearn") { model.relearn(entry.id) }
                        .disabled(!model.canRelearn(entry.id))
                        .accessibilityLabel("Relearn writing style for \(entry.email)")
                        .help("Read recent sent mail and replace this account’s writing profile.")
                }
            }
        }
    }
}
