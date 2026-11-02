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
    var onOpenMessage: ((MailOrganizationSample) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s3) {
                phaseStep(1, title: "Analyze")
                phaseConnector(completed: currentStep > 1)
                phaseStep(2, title: "Review")
                phaseConnector(completed: currentStep > 2)
                phaseStep(3, title: "Apply")
            }
            .padding(.horizontal, Tokens.Space.s6)
            .padding(.vertical, Tokens.Space.s4)
            .background(Tokens.Surface.primary)
            Divider()
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
            // Each phase starts at the top without changing the account-owned model.
            .id(model.phase)
            .transition(.opacity)
            if model.phase == .review && !model.categories.isEmpty {
                MailOrganizationReviewFooter(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ternAnimation(value: model.phase)
    }

    private var currentStep: Int {
        switch model.phase {
        case .idle, .reading, .analyzing: 1
        case .review: 2
        case .applying, .queued, .complete: 3
        }
    }

    private func phaseStep(_ number: Int, title: String) -> some View {
        let completed = number < currentStep || model.phase == .complete
        let current = number == currentStep
        return HStack(spacing: Tokens.Space.s2) {
            Group {
                if completed { Image(systemName: "checkmark") } else { Text(number, format: .number) }
            }
            .font(.callout.weight(.semibold))
            .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
            .background(current ? Color.accentColor.opacity(Tokens.Opacity.tint) : Color.primary.opacity(Tokens.Opacity.wash), in: Circle())
            Text(title).font(.callout.weight(current ? .semibold : .regular))
                .fixedSize()
        }
        .foregroundStyle(current ? Color.accentColor : completed ? Color.primary : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number): \(title), \(completed ? "complete" : current ? "current step" : "up next")")
    }

    private func phaseConnector(completed: Bool) -> some View {
        Rectangle().fill(completed ? Color.accentColor : Tokens.Surface.border)
            .frame(maxWidth: .infinity).frame(height: Tokens.Border.hairline)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .idle:
            MailOrganizationIntroduction(canAnalyze: model.canAnalyze, requirement: requirement,
                onAnalyze: model.startAnalysis, onOpenSettings: onOpenSettings)
        case .reading, .analyzing:
            MailOrganizationLoadingView(phase: model.phase, progress: model.samplingProgress,
                startedAt: model.analysisStartedAt, sampleCount: model.samples?.messages.count ?? 0,
                onCancel: model.clear)
        case .review:
            if model.categories.isEmpty {
                emptyReview
            } else {
                MailOrganizationReviewSections(model: model, canCreateFilters: canCreateFilters, onOpenMessage: onOpenMessage)
            }
        case .applying, .queued, .complete:
            MailOrganizationDeliveryView(phase: model.phase, receipt: model.receipt, delivery: model.delivery,
                onCheck: { Task { await model.refreshDelivery() } },
                onOpenFailedChanges: { onOpenSettings(.failedChanges) }, onDone: model.clear)
            MailOrganizationReviewSections(model: model, canCreateFilters: canCreateFilters, onOpenMessage: onOpenMessage)
        }
    }

    private var emptyReview: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No clear suggestions yet")
                .font(.title2.weight(.semibold))
            Text("The available previews didn't show enough consistent patterns to suggest useful labels.")
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
            Button("Analyze again", systemImage: "arrow.clockwise", action: model.startAnalysis)
                .buttonStyle(.borderedProminent).disabled(!model.canAnalyze)
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }
}
