import SwiftUI

/// Review content is independent of account connections and can render a
/// prepared plan without reading mail or starting an assistant request.
struct MailOrganizationReviewSections: View {
    @Bindable var model: MailOrganizationModel
    let canCreateFilters: Bool

    var body: some View {
        if let samples = model.samples {
            Section("Review categories") {
                Text("Based on \(samples.messages.count) recent messages: \(samples.messages.filter { !$0.isSent }.count) received and \(samples.messages.filter(\.isSent).count) sent.")
                    .font(.callout).foregroundStyle(.secondary)
                if samples.isPartial {
                    SettingsNote("Some recent messages could not be read. You can label the available messages; future filters need a complete sample.",
                                 systemImage: "exclamationmark.triangle")
                }
                if model.categories.isEmpty {
                    Text("No clear categories emerged from these messages. You can try again as new mail arrives.")
                        .foregroundStyle(.secondary)
                } else {
                    SettingsNote("Review the names and examples before applying. Matching labels already in Gmail are reused.")
                    SettingsNote("Action and Waiting reflect only this sample. Recheck them as conversations change.")
                }
            }
            ForEach($model.categories) { $category in
                MailOrganizationCategoryRow(category: $category, samples: samples,
                    canCreateFilters: canCreateFilters && !samples.isPartial)
                    .disabled(model.phase != .review)
            }
        }
    }
}

struct MailOrganizationReviewFooter: View {
    @Bindable var model: MailOrganizationModel

    var body: some View {
        SettingsFooter {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                if let message = model.validationMessage {
                    SettingsNote(message, systemImage: "exclamationmark.circle")
                }
                HStack(spacing: Tokens.Space.s3) {
                    Text("\(model.selectedCount) \(model.selectedCount == 1 ? "category" : "categories")"
                        + " · \(model.selectedMessageCount) \(model.selectedMessageCount == 1 ? "message" : "messages")"
                        + " · \(model.selectedFilterCount) \(model.selectedFilterCount == 1 ? "filter" : "filters")")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Apply to Gmail") { model.applySelection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canApply)
                        .accessibilityIdentifier("organization.apply")
                }
            }
        }
    }
}
