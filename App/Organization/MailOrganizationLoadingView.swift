import SwiftUI
import SyncEngine

struct MailOrganizationLoadingView: View {
    let phase: MailOrganizationModel.Phase
    let progress: MailOrganizationSamplingProgress?
    let startedAt: Date?
    let sampleCount: Int
    let onCancel: () -> Void

    private var isAnalyzing: Bool { phase == .analyzing }

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
                    Text(isAnalyzing ? "Finding your labels" : "Reading recent mail")
                        .font(.title2.weight(.semibold))
                    Text(detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                if !isAnalyzing, let progress, progress.stage == .reading, progress.selectedCount > 0 {
                    ProgressView(value: Double(progress.processedCount), total: Double(progress.selectedCount))
                        .accessibilityLabel("Reading recent mail")
                        .accessibilityValue("\(progress.processedCount) of \(progress.selectedCount) messages checked")
                } else {
                    ProgressView().progressViewStyle(.linear)
                        .accessibilityLabel(isAnalyzing ? "Analyzing messages" : "Loading recent mail")
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
                step("Read recent mail", detail: isAnalyzing ? "\(sampleCount) messages ready" : "Received and sent, together",
                     state: isAnalyzing ? .complete : .current)
                step("Find patterns", detail: "Topics, recurring senders, and requests",
                     state: isAnalyzing ? .current : .upcoming)
                step("Review suggestions", detail: "Choose labels and check their examples", state: .upcoming)
            }
            Divider()
            HStack(spacing: Tokens.Space.s3) {
                Text("Nothing in Gmail changes until you apply.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
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

    private var detail: String {
        if isAnalyzing {
            return "Looking for useful categories across \(sampleCount) recent messages."
        }
        switch progress?.stage {
        case .labels: return "Checking the labels you already use."
        case .listing: return "Selecting up to 250 received and sent messages."
        case .reading:
            return "Reading message headers and short previews."
        case nil: return "Connecting to your Google account."
        }
    }

    private var progressCaption: String {
        if isAnalyzing { return "Analyzing with ChatGPT…" }
        guard let progress else { return "Starting…" }
        switch progress.stage {
        case .labels: return "Loading existing labels…"
        case .listing: return "Finding recent messages…"
        case .reading: return "\(progress.processedCount) of \(progress.selectedCount) messages checked"
        }
    }

    private enum StepState { case complete, current, upcoming }

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
