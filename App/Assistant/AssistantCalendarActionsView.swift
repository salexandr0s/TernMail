import SwiftUI

struct AssistantCalendarActionsView: View {
    let message: AssistantMessage
    @Bindable var model: AssistantModel
    @State private var selected = Set<UUID>()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
            ForEach(message.calendarProposals) { proposal in
                Button {
                    model.reviewCalendarProposal(proposal)
                    openWindow(id: RootView.sceneID)
                } label: {
                    HStack(alignment: .top, spacing: Tokens.Space.s2) {
                        Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary)
                        Text(proposal.title).font(Tokens.AssistantFormatting.titleFont)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }
                    .font(Tokens.AssistantFormatting.metadataFont)
                    .padding(Tokens.AssistantFormatting.inset)
                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
                    .ternOutline(radius: Tokens.AssistantFormatting.cornerRadius, style: .contrastOnly)
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
                .help("Review \(proposal.title)\nReview the proposed event before saving it")
                .accessibilityLabel("Review \(proposal.title)")
            }
            if !message.availabilityChoices.isEmpty {
                Text("Choose times to suggest").font(Tokens.AssistantFormatting.titleFont)
                ForEach(message.availabilityChoices) { choice in
                    Toggle(isOn: $selected.contains(choice.id)) {
                        Text(choice.displayTitle).font(Tokens.AssistantFormatting.supportingFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(minHeight: Tokens.Space.s6)
                    }
                    .toggleStyle(.checkbox)
                    .help("\(choice.displayTitle) · \(choice.timeZoneIdentifier)")
                    .accessibilityLabel("\(choice.displayTitle), \(choice.timeZoneIdentifier)")
                    .disabled(model.isRunning || model.isCheckingCalendarAvailability)
                }
                if let choice = message.availabilityChoices.first {
                    FlowLayout(spacing: Tokens.Space.s2) {
                        Text(choice.timeZoneIdentifier)
                        Text("Checked \(choice.calendarKeys.count) \(choice.calendarKeys.count == 1 ? "calendar" : "calendars") at \(choice.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                }
                Button {
                    let choices = message.availabilityChoices.filter { selected.contains($0.id) }
                    Task { await model.useAvailabilityChoices(choices) }
                } label: {
                    Label(model.isCheckingCalendarAvailability ? "Checking availability…" : "Use selected times in a reply",
                          systemImage: "square.and.pencil")
                        .font(Tokens.AssistantFormatting.supportingFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || selected.count > 6 || model.isRunning || model.isCheckingCalendarAvailability)
                Text("Tern checks again before drafting. These times are not reserved.")
                    .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.calendarChoiceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Tokens.AssistantFormatting.inset)
    }
}
