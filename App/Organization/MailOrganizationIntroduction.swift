import SwiftUI

struct MailOrganizationIntroduction: View {
    @Binding var maximumMessages: Int
    let canAnalyze: Bool
    let requirement: MailOrganizationRequirement?
    let onAnalyze: () -> Void
    let onOpenSettings: (SettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                HStack(alignment: .top, spacing: Tokens.Space.s4) {
                    Image(systemName: "tag.fill")
                        .font(.title2).foregroundStyle(Color.accentColor)
                        .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                        .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Text("Build on your labels and rules")
                            .font(.title2.weight(.semibold))
                        Text("Analyze your mail in batches, combine related themes, and review a plan for new labels and rules.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    step("envelope", title: "Read mail and your existing setup", detail: "Received and sent messages, existing labels, and Gmail rules.")
                    step("arrow.triangle.merge", title: "Compare and recheck", detail: "Combine batch findings, then check the mail against the shared plan.")
                    step("checkmark.icloud", title: "Review and apply", detail: "Choose future-mail rules and whether to back-tag matching mail.")
                }
                Divider()
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Picker("Mail to analyze", selection: $maximumMessages) {
                        ForEach([1_000, 5_000, 20_000, 100_000], id: \.self) { count in
                            Text("Up to \(count.formatted()) messages").tag(count)
                        }
                    }
                    .accessibilityIdentifier("organization.scanLimit")
                    Text("Larger scans take longer. You can leave Settings while the job runs; interrupted analysis can resume from its last completed batch.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let requirement {
                    Label(requirement.message, systemImage: "lock")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button(requirement.destination == .connections ? "Open Connections" : "Open Assistant Settings") {
                        onOpenSettings(requirement.destination)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("Analyze mail", systemImage: "sparkles", action: onAnalyze)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!canAnalyze)
                        .accessibilityIdentifier("organization.analyze")
                }
            }
            .padding(Tokens.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ternSurface()

            Label {
                Text("Analysis shares message headers, short previews, labels, and rule settings with your connected ChatGPT account. Nothing changes in Gmail until you review and apply the plan.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, Tokens.Space.s1)
        }
    }

    private func step(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s5, height: Tokens.Space.s5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
