import SwiftUI
import SyncEngine

struct MailOrganizationRequirement {
    let message: String
    let destination: SettingsDestination
}

/// The presentation depends only on a review model, so every phase can be
/// inspected without opening a live account or starting an AI request.
struct MailOrganizationExperience: View {
    @Bindable var model: MailOrganizationModel
    let canCreateFilters: Bool
    var requirement: MailOrganizationRequirement? = nil
    var onOpenSettings: (SettingsDestination) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.callout).foregroundStyle(Tokens.Status.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Tokens.Space.s4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .ternSurface()
                    }
                    phaseContent
                }
                .padding(Tokens.Space.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            // A new phase starts at the top; editing choices preserves review scroll.
            .id(model.phase)
            .transition(.opacity)
            if model.phase == .review && !model.categories.isEmpty {
                MailOrganizationReviewFooter(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ternAnimation(value: model.phase)
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .idle:
            MailOrganizationIntroduction(maximumMessages: $model.scanMaximumMessages,
                canAnalyze: model.canAnalyze, requirement: requirement,
                onAnalyze: model.startAnalysis, onOpenSettings: onOpenSettings)
        case .reading, .analyzing, .paused:
            MailOrganizationLoadingView(phase: model.phase, progress: model.samplingProgress,
                analysisProgress: model.analysisProgress,
                startedAt: model.analysisStartedAt, sampleCount: model.samples?.messages.count ?? 0,
                scanMaximumMessages: model.scanMaximumMessages, onResume: model.resumeAnalysis,
                onCancel: model.clear)
        case .review:
            if model.categories.isEmpty {
                emptyReview
            } else {
                MailOrganizationReviewSections(model: model, canCreateFilters: canCreateFilters)
            }
        case .applying, .queued, .complete:
            MailOrganizationDeliveryView(phase: model.phase, receipt: model.receipt, delivery: model.delivery,
                onCheck: { Task { await model.refreshDelivery() } },
                onOpenFailedChanges: { onOpenSettings(.failedChanges) }, onDone: model.clear)
            MailOrganizationReviewSections(model: model, canCreateFilters: canCreateFilters)
        }
    }

    private var emptyReview: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(model.samples?.messages.isEmpty == true ? "No mail to organize yet" : "No clear suggestions yet")
                .font(.title2.weight(.semibold))
            Text(model.samples?.messages.isEmpty == true
                 ? "This account has no eligible messages to analyze. You can check again when mail arrives."
                 : "The available previews didn't show enough consistent patterns to suggest useful labels.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let samples = model.samples {
                Text("Checked \(samples.messages.count) recent \(samples.messages.count == 1 ? "message" : "messages").")
                    .font(.callout).foregroundStyle(.secondary)
                if samples.isPartial {
                    Label("Some messages couldn't be read. Try again when your account is connected.",
                          systemImage: "exclamationmark.circle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(model.samples?.messages.isEmpty == true ? "Check again" : "Analyze again",
                   systemImage: "arrow.clockwise", action: model.startAnalysis)
                .buttonStyle(.borderedProminent).disabled(!model.canAnalyze)
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }
}
