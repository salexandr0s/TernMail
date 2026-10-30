import SwiftUI

struct AssistantWritingStyleSettingsSection: View {
    @Bindable var model: AssistantWritingStyleModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text("Writing style")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Space.s1)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Text("Learn how you write from up to 100 recent sent emails in each enabled account. Replies use that account’s style and follow any tone you request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Tokens.Space.s3)
                ForEach(model.entries) { entry in
                    Divider()
                    accountRow(entry)
                }
                if model.entries.isEmpty {
                    Label("Add a mail account to learn your writing style.", systemImage: "envelope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(Tokens.Space.s3)
                }
                if let error = model.storageErrorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(Tokens.Space.s3)
                }
                Divider()
                Text("Excerpts are sent to ChatGPT during setup. Only the learned preferences are saved on this device. Turning learning off deletes the profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Tokens.Space.s3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSurface()
        }
    }

    private func accountRow(_ entry: AssistantWritingStyleEntry) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                TernAvatar(name: entry.displayName ?? entry.email, size: Tokens.Space.s6)
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
                Spacer(minLength: Tokens.Space.s2)
                Toggle("Learn my writing style", isOn: Binding(
                    get: { model.isEnabled(entry.id) },
                    set: { model.setEnabled(entry.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Learn writing style for \(entry.email)")
                .accessibilityHint("Turning this off deletes the account’s learned profile.")
            }
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!model.canRelearn(entry.id))
                        .accessibilityLabel("Relearn writing style for \(entry.email)")
                        .help("Read recent sent mail and replace this account’s writing profile.")
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
    }
}
