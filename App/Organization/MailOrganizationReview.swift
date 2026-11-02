import SwiftUI

/// Review content is independent of account connections and can render a
/// prepared plan without reading mail or starting an assistant request.
struct MailOrganizationReviewSections: View {
    @Bindable var model: MailOrganizationModel
    let canCreateFilters: Bool

    private var isReviewing: Bool { model.phase == .review }
    private var allSelected: Bool { model.selectedCount == model.categories.count }
    private var title: String {
        switch model.phase {
        case .review: "Suggested labels"
        case .complete: "Applied labels"
        default: "Selected labels"
        }
    }

    var body: some View {
        if let samples = model.samples {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        if isReviewing && !model.categories.isEmpty {
                            Button(allSelected ? "Deselect All" : "Select All") {
                                let selected = !allSelected
                                for index in model.categories.indices { model.categories[index].isSelected = selected }
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .accessibilityIdentifier("organization.selectAll")
                        }
                    }
                    Text("\(samples.messages.count) analyzed · \(samples.messages.filter { !$0.isSent }.count) received · \(samples.messages.filter(\.isSent).count) sent")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.categories.isEmpty {
                        Text("Expand a label to review example messages.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if samples.isPartial {
                    SettingsNote("Some messages were unavailable. You can label this sample; future filters need a complete sample.",
                                 systemImage: "exclamationmark.triangle")
                }
                if model.categories.isEmpty {
                    TernEmptyState(title: "No labels suggested", systemImage: "tag",
                        message: "These messages didn't suggest consistent categories. Try again as new mail arrives.",
                        fillsSpace: false)
                        .ternSurface()
                } else {
                    ForEach($model.categories) { $category in
                        if isReviewing || category.isSelected {
                            MailOrganizationCategoryRow(category: $category, samples: samples,
                                canCreateFilters: canCreateFilters && !samples.isPartial,
                                isEditable: isReviewing, isApplied: model.phase == .complete)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MailOrganizationReviewFooter: View {
    @Bindable var model: MailOrganizationModel

    var body: some View {
        SettingsFooter {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                if model.selectedCount > 0, let message = model.validationMessage {
                    SettingsNote(message, systemImage: "exclamationmark.circle")
                }
                HStack(spacing: Tokens.Space.s3) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                        Text("\(model.selectedCount) \(model.selectedCount == 1 ? "label" : "labels") selected")
                            .font(.callout.weight(.medium))
                        Text(messageSummary)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Start Over") { model.clear() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("organization.startOver")
                    Button("Apply to Gmail") { model.applySelection() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.canApply)
                        .accessibilityIdentifier("organization.apply")
                }
            }
        }
    }

    private var messageSummary: String {
        let messages = "\(model.selectedMessageCount) \(model.selectedMessageCount == 1 ? "message" : "messages")"
        guard model.selectedFilterCount > 0 else { return messages }
        return messages + " · \(model.selectedFilterCount) \(model.selectedFilterCount == 1 ? "filter" : "filters")"
    }
}
