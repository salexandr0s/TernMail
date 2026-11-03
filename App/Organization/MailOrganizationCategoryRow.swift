import SwiftUI
import SyncEngine

struct MailOrganizationCategoryRow: View {
    @Binding var category: MailOrganizationReviewCategory
    let samples: MailOrganizationSamples
    let canCreateFilters: Bool
    var isEditable = true
    var isApplied = false
    @State private var isDetailsExpanded = false

    private var displayName: String {
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled label" : name
    }

    private var reusesLabel: Bool {
        category.existingLabelID != nil || samples.existingLabels.contains {
            !$0.isSystem && $0.name.caseInsensitiveCompare(displayName) == .orderedSame
        }
    }

    private var coverage: OrganizationRuleCoverage {
        let senders = samples.eligibleRuleSenders(category.proposal.ruleSenders,
                                                selectedMessageIDs: category.selectedMessageIDs)
        return samples.ruleCoverage(existingLabelID: category.existingLabelID,
                                    labelName: category.name, proposedSenders: senders)
    }

    private var futureChoice: Binding<Bool> {
        Binding(get: { category.isSelected && category.createsFilter },
                set: { category.setFutureMail($0) })
    }

    private var backfillChoice: Binding<Bool> {
        Binding(get: { category.isSelected && category.backfillExisting },
                set: { category.setBackfill($0) })
    }

    private var ruleTitle: String {
        coverage.newFilterCount == 1 ? "Create a rule for future mail" : "Create \(coverage.newFilterCount.formatted()) rules for future mail"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: "tag.fill")
                    .font(.body).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(displayName).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(reusesLabel ? "Use existing label" : "Create new label")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !category.isSelected && isEditable {
                    TernBadge(text: "Skipped")
                }
            }

            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Why this is suggested").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(category.proposal.explanation)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            if isEditable {
                choices
            } else {
                savedChoices
            }

            if (category.existingLabelID == nil && isEditable) || !coverage.newSenders.isEmpty || !coverage.alreadyCoveredSenders.isEmpty {
                DisclosureGroup(category.existingLabelID == nil && isEditable ? "Label details" : "Matching senders",
                                isExpanded: $isDetailsExpanded) {
                    matchDetails
                        .padding(.top, Tokens.Space.s2)
                        .ternTransition(.disclosure)
                }
                .font(.caption)
                .accessibilityIdentifier("organization.category.\(category.id).details")
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
        .ternAnimation(value: isDetailsExpanded, duration: Tokens.Motion.slow)
        .accessibilityElement(children: .contain)
        .onChange(of: coverage.newFilterCount, initial: true) { _, count in
            if isEditable && count == 0 && category.createsFilter { category.setFutureMail(false) }
        }
    }

    @ViewBuilder private var choices: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            if coverage.newFilterCount > 0 {
                Toggle(isOn: futureChoice) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(ruleTitle).font(.callout.weight(.medium))
                        Text("From \(senderPreview). Add the \(displayName) label.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!canCreateFilters)
                .accessibilityIdentifier("organization.category.\(category.id).future")
                if !canCreateFilters {
                    Text("Gmail Settings access is needed to create future-mail rules.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !coverage.alreadyCoveredSenders.isEmpty {
                Label("Future mail is already covered by your rules", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("A label for existing mail; no recurring sender rule is suggested.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle(isOn: backfillChoice) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Back-tag \(category.selectedMessageIDs.count.formatted()) matching \(category.selectedMessageIDs.count == 1 ? "message" : "messages")")
                        .font(.callout.weight(.medium))
                    Text("Add this label to matching mail from this scan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("organization.category.\(category.id).backfill")

            if coverage.existingRuleCount > 0 {
                Text("Your existing rules stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if category.proposal.kind != .topic {
                Text("This label does not clear automatically when a reply arrives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var senderPreview: String {
        let senders = coverage.newSenders
        let first = senders.prefix(2).joined(separator: ", ")
        return senders.count > 2 ? first + " and \((senders.count - 2).formatted()) more" : first
    }

    private var savedChoices: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if category.createsFilter && coverage.newFilterCount > 0 {
                Label("\(coverage.newFilterCount.formatted()) \(coverage.newFilterCount == 1 ? "rule" : "rules") for future mail", systemImage: "arrow.forward.to.line")
            }
            if category.backfillExisting {
                Label("\(category.selectedMessageIDs.count.formatted()) \(category.selectedMessageIDs.count == 1 ? "message" : "messages") \(isApplied ? "back-tagged" : "to back-tag")", systemImage: "tag")
            }
        }
        .font(.callout)
    }

    private var matchDetails: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if category.existingLabelID == nil && isEditable {
                TextField("Label name", text: $category.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Gmail label name")
            }
            if !coverage.newSenders.isEmpty {
                Text(coverage.newSenders.joined(separator: "\n"))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !coverage.alreadyCoveredSenders.isEmpty {
                Text("Already covered: \(coverage.alreadyCoveredSenders.joined(separator: ", "))")
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if coverage.newSenders.isEmpty && coverage.alreadyCoveredSenders.isEmpty {
                Text("This suggestion applies to the matching messages in this scan.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
