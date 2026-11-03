import SwiftUI
import SyncEngine

struct MailOrganizationReviewSections: View {
    @Bindable var model: MailOrganizationModel
    let canCreateFilters: Bool

    private var isReviewing: Bool { model.phase == .review }
    private var ruleCount: Int { model.categories.filter { !$0.proposal.ruleSenders.isEmpty }.count }

    var body: some View {
        if let samples = model.samples {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text(isReviewing ? "Choose your labels and rules" : "Your selected changes")
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(isReviewing
                         ? "Choose what should happen to future mail, and whether to back-tag matching mail already here."
                         : "Your rule and back-tagging choices are shown below.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Based on \(samples.messages.count.formatted()) \(samples.messages.count == 1 ? "message" : "messages") · \(samples.filterContextAvailable ? "existing labels and rules considered" : "existing labels considered")")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if samples.hasMore || samples.isPartial || !samples.filterContextAvailable {
                    coverageNotes(samples)
                }
                if isReviewing {
                    HStack(spacing: Tokens.Space.s4) {
                        Button("Select all") { model.setAllSuggestionsSelected(true) }
                            .accessibilityIdentifier("organization.selectAll")
                        Button("Clear selection") { model.setAllSuggestionsSelected(false) }
                            .accessibilityIdentifier("organization.clearSelection")
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
                if ruleCount > 0 {
                    suggestions(title: "Rules for future mail", hasRule: true, samples: samples)
                }
                if ruleCount < model.categories.count {
                    suggestions(title: ruleCount > 0 ? "Other label suggestions" : "Labels for existing mail",
                                hasRule: false, samples: samples)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func suggestions(title: String, hasRule: Bool, samples: MailOrganizationSamples) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach($model.categories) { $category in
                if (!category.proposal.ruleSenders.isEmpty) == hasRule && (isReviewing || category.isSelected) {
                    MailOrganizationCategoryRow(category: $category, samples: samples,
                        canCreateFilters: canCreateFilters && !samples.isPartial,
                        isEditable: isReviewing, isApplied: model.phase == .complete)
                }
            }
        }
    }

    private func coverageNotes(_ samples: MailOrganizationSamples) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if samples.isPartial {
                SettingsNote("Some mail could not be checked. Back-tagging is available; new future-mail rules need a complete scan.",
                             systemImage: "exclamationmark.triangle")
            } else if samples.hasMore {
                SettingsNote("The scan reached its limit. Back-tagging covers matching mail from this scan.",
                             systemImage: "tray.full")
            }
            if !samples.filterContextAvailable {
                SettingsNote("Enable Gmail Settings access in Connections to include future-mail rules.", systemImage: "lock")
            }
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.s4) {
                        selectionSummary.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        actions
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        selectionSummary
                        HStack {
                            Spacer(minLength: 0)
                            actions
                        }
                    }
                }
            }
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(model.selectedCount == 0 ? "No changes selected" : actionSummary)
                .font(.callout.weight(.medium))
            Text(model.selectedCount == 0
                 ? "Choose a rule or back-tagging above."
                 : "Labels: \(model.selectedExistingLabelCount) existing · \(model.selectedNewLabelCount) new")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionSummary: String {
        let rules = "\(model.selectedFilterCount.formatted()) new \(model.selectedFilterCount == 1 ? "rule" : "rules")"
        let mail = model.selectedMessageCount == 0
            ? "no back-tagging"
            : "\(model.selectedMessageCount.formatted()) \(model.selectedMessageCount == 1 ? "message" : "messages") to back-tag"
        return rules + " · " + mail
    }

    private var actions: some View {
        HStack(spacing: Tokens.Space.s3) {
            Button("Start Over") { model.clear() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("organization.startOver")
            Button("Apply to Gmail") { model.applySelection() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.canApply)
                .accessibilityIdentifier("organization.apply")
        }
    }
}
