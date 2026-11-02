import SwiftUI

struct MailOrganizationIntroduction: View {
    let canAnalyze: Bool
    let requirement: MailOrganizationRequirement?
    let onAnalyze: () -> Void
    let onOpenSettings: (SettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                Image(systemName: "tag.fill")
                    .font(.largeTitle).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Labels that fit your mail")
                        .font(.title2.weight(.semibold))
                    Text("Turn recent conversations and recurring mail into a set of labels you can review and make your own.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    step("envelope", title: "Read your recent mail", detail: "Up to 250 received and sent messages combined.")
                    step("tag", title: "Review the suggestions", detail: "See examples, rename labels, and choose what to keep.")
                    step("checkmark.icloud", title: "Apply to Gmail", detail: "Save your labels and any sender rules you choose.")
                }
                Divider()
                if let requirement {
                    Label(requirement.message, systemImage: "lock")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button(requirement.destination == .connections ? "Open Connections" : "Open Assistant Settings") {
                        onOpenSettings(requirement.destination)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("Analyze recent mail", systemImage: "sparkles", action: onAnalyze)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!canAnalyze)
                        .accessibilityIdentifier("organization.analyze")
                }
            }
            .padding(Tokens.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ternSurface()

            Label {
                Text("Analysis shares message headers, short previews, and existing label names with your connected ChatGPT account. You choose what gets applied to Gmail.")
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
