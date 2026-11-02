import SwiftUI
import SyncEngine

struct MailOrganizationCategoryRow: View {
    @Binding var category: MailOrganizationReviewCategory
    let samples: MailOrganizationSamples
    let canCreateFilters: Bool

    private var examples: [MailOrganizationSample] {
        let ids = Set(category.proposal.messageIDs)
        return samples.messages.filter { ids.contains($0.messageID) }
    }

    private var reusesLabel: Bool {
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return samples.existingLabels.contains { !$0.isSystem && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var body: some View {
        Section {
            Toggle(isOn: $category.isSelected) {
                Text(category.proposal.name).font(.headline)
                Text(category.proposal.explanation).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Include \(category.proposal.name)")

            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                TextField("Label name", text: $category.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Gmail label name for \(category.proposal.name)")
                Label(reusesLabel ? "Uses an existing Gmail label" : "Creates a Gmail label",
                      systemImage: reusesLabel ? "tag" : "tag.badge.plus")
                    .font(.caption).foregroundStyle(.secondary)

                if category.proposal.kind == .topic && !category.proposal.ruleSenders.isEmpty {
                    Toggle("Label future mail from these senders", isOn: $category.createsFilter)
                        .toggleStyle(.switch)
                        .disabled(!canCreateFilters)
                    Text(category.proposal.ruleSenders.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsNote("The Gmail filters match all new incoming messages from these addresses, regardless of their topic.")
                } else {
                    SettingsNote(category.proposal.kind == .topic
                        ? "Applies to these sampled messages. There isn't enough consistent sender history for an automatic filter."
                        : "Applies to these sampled messages. These labels do not clear automatically when a reply arrives.")
                }

                DisclosureGroup("\(examples.count) sampled \(examples.count == 1 ? "message" : "messages")") {
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        ForEach(examples, id: \.messageID) { message in
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                                    .font(.callout).lineLimit(2)
                                Text("\(message.isSent ? "Sent" : "Received") · \(message.sender)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, Tokens.Space.s2)
                }
            }
            .disabled(!category.isSelected)
        }
    }
}
