import SwiftUI
import SyncEngine
import TernAI

struct MailOrganizationLoadingView: View {
    let phase: MailOrganizationModel.Phase
    let progress: MailOrganizationSamplingProgress?
    let analysisProgress: OrganizationAnalysisProgress?
    let startedAt: Date?
    let sampleCount: Int
    let scanMaximumMessages: Int
    let onResume: () -> Void
    let onCancel: () -> Void

    private var isAnalyzing: Bool { phase == .analyzing || phase == .paused }
    private var isPaused: Bool { phase == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            HStack(alignment: .top, spacing: Tokens.Space.s4) {
                Image(systemName: isAnalyzing ? "sparkles" : "envelope")
                    .font(.title).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                if isAnalyzing, let analysisProgress, analysisProgress.totalBatches > 0 {
                    ProgressView(value: Double(analysisProgress.completedBatches), total: Double(analysisProgress.totalBatches))
                        .accessibilityLabel(title)
                        .accessibilityValue(progressCaption)
                } else if !isAnalyzing, let progress, progress.stage == .reading, progress.selectedCount > 0 {
                    ProgressView(value: Double(progress.processedCount), total: Double(progress.selectedCount))
                        .accessibilityLabel("Reading mail")
                        .accessibilityValue("\(progress.processedCount) of \(progress.selectedCount) messages checked")
                } else {
                    ProgressView().progressViewStyle(.linear)
                        .accessibilityLabel(title)
                }
                HStack {
                    Text(progressCaption).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: Tokens.Space.s2)
                    if let startedAt {
                        HStack(spacing: Tokens.Space.s1) {
                            Text("Elapsed")
                            Text(startedAt, style: .timer).monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    }
                }
            }

            VStack(spacing: Tokens.Space.s4) {
                step("Read mail and existing setup", detail: isAnalyzing ? "\(sampleCount.formatted()) messages ready" : "Received mail, sent mail, labels, and rules",
                     state: state(for: 0))
                step("Find patterns in batches", detail: "Topics, recurring senders, and requests", state: state(for: 1))
                step("Combine related findings", detail: "Build on the labels and rules you already use", state: state(for: 2))
                step("Recheck the mail", detail: "Compare every batch with the combined plan", state: state(for: 3))
                step("Prepare your review", detail: "Choose future rules and optional back-tagging", state: state(for: 4))
            }
            Divider()
            HStack(spacing: Tokens.Space.s3) {
                Text(isPaused ? "Progress is saved while Tern stays open." : "You can leave Settings. Nothing in Gmail changes until you apply.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isPaused {
                    Button("Resume analysis", systemImage: "play.fill", action: onResume)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("organization.resume")
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel mail analysis")
                    .accessibilityIdentifier("organization.cancel")
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }

    private var title: String {
        if isPaused { return "Analysis paused" }
        guard isAnalyzing else { return "Reading your mailbox" }
        switch analysisProgress?.stage {
        case .discovering: return "Finding patterns in your mail"
        case .consolidating: return "Combining batch findings"
        case .auditing: return "Checking the combined plan"
        case .validating: return "Checking labels and rules"
        case nil: return "Starting batch analysis"
        }
    }

    private var detail: String {
        if isPaused { return "Resume from the last completed batch when the connection is available." }
        if isAnalyzing {
            switch analysisProgress?.stage {
            case .discovering: return "Looking for useful topics across \(sampleCount.formatted()) messages."
            case .consolidating: return "Grouping related findings and comparing them with your existing labels and rules."
            case .auditing: return "Reading each batch again to check its label assignments against the shared plan."
            case .validating: return "Checking sender patterns and conversation state across the complete scan."
            case nil: return "Preparing the first batch. Larger scans can take a while."
            }
        }
        switch progress?.stage {
        case .labels: return "Checking the labels you already use."
        case .rules: return "Checking the Gmail rules you already have."
        case .listing: return "Selecting up to \(scanMaximumMessages.formatted()) received and sent messages."
        case .reading:
            return "Reading message headers and short previews."
        case nil: return "Connecting to your Google account."
        }
    }

    private var progressCaption: String {
        if isAnalyzing {
            guard let analysisProgress else { return "Preparing analysis…" }
            let unit = analysisProgress.stage == .consolidating ? "comparisons" : "batches"
            return "\(analysisProgress.completedBatches) of \(analysisProgress.totalBatches) \(unit) · \(analysisProgress.analyzedCount.formatted()) messages"
        }
        guard let progress else { return "Starting…" }
        switch progress.stage {
        case .labels: return "Loading existing labels…"
        case .rules: return "Loading existing rules…"
        case .listing: return "Finding recent messages…"
        case .reading: return "\(progress.processedCount) of \(progress.selectedCount) messages checked"
        }
    }

    private enum StepState { case complete, current, upcoming }

    private func state(for index: Int) -> StepState {
        let active: Int
        if !isAnalyzing { active = 0 }
        else {
            switch analysisProgress?.stage {
            case .discovering, nil: active = 1
            case .consolidating: active = 2
            case .auditing: active = 3
            case .validating: active = 4
            }
        }
        return index < active ? .complete : index == active ? .current : .upcoming
    }

    private func step(_ title: String, detail: String, state: StepState) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: state == .complete ? "checkmark.circle.fill" : state == .current ? "circle.inset.filled" : "circle")
                .font(.title3)
                .foregroundStyle(state == .complete ? Tokens.Status.success : state == .current ? Color.accentColor : Color.secondary)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.body.weight(state == .current ? .semibold : .medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(state == .complete ? "complete" : state == .current ? "in progress" : "up next"). \(detail)")
    }
}
