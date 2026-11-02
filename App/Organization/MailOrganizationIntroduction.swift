import SwiftUI

struct MailOrganizationIntroduction: View {
    let canAnalyze: Bool
    let requirement: MailOrganizationRequirement?
    let onAnalyze: () -> Void
    let onOpenSettings: (SettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s6) {
            HStack(alignment: .top, spacing: Tokens.Space.s4) {
                Image(systemName: "tag.fill")
                    .font(.largeTitle).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Start with your recent mail")
                        .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Find label suggestions from up to 250 received and sent messages combined.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                expectation("checklist", title: "Review every suggestion",
                    detail: "Check examples, rename labels, and choose the messages to include.")
                expectation("tray.and.arrow.down", title: "Choose what reaches Gmail",
                    detail: "Apply labels to the reviewed messages. Add sender rules for future mail where available.")
            }
            .padding(Tokens.Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Label("Shared with ChatGPT", systemImage: "hand.raised")
                    .font(.callout.weight(.semibold))
                Text("Analysis shares message headers, short previews, and existing label names with your connected ChatGPT account. You choose what gets applied to Gmail.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing in Gmail changes until you apply.")
                    .font(.callout.weight(.medium))
            }
            Divider()
            if let requirement {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    Label(requirement.message, systemImage: "lock")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button(requirement.destination == .connections ? "Open Connections" : "Open Assistant Settings") {
                        onOpenSettings(requirement.destination)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
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
    }

    private func expectation(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
