import SwiftUI

struct AssistantCalendarActionsView: View {
    let message: AssistantMessage
    @Bindable var model: AssistantModel
    @State private var selected = Set<UUID>()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            ForEach(message.calendarProposals) { proposal in
                Button {
                    model.reviewCalendarProposal(proposal)
                    openWindow(id: RootView.sceneID)
                } label: {
                    Label("Review \(proposal.title)", systemImage: "calendar.badge.plus")
                        .lineLimit(2)
                }
                .buttonStyle(.bordered)
                .help("Review the proposed event before saving it")
            }
            if !message.availabilityChoices.isEmpty {
                Text("Choose times to suggest").font(.callout.weight(.medium))
                ForEach(message.availabilityChoices) { choice in
                    Toggle(isOn: $selected.contains(choice.id)) {
                        Text(choice.displayTitle).font(.callout)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(model.isRunning || model.isCheckingCalendarAvailability)
                }
                Text(message.availabilityChoices.first?.timeZoneIdentifier ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                if let choice = message.availabilityChoices.first {
                    Text("Checked \(choice.calendarKeys.count) calendars at \(choice.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    let choices = message.availabilityChoices.filter { selected.contains($0.id) }
                    Task { await model.useAvailabilityChoices(choices) }
                } label: {
                    Label(model.isCheckingCalendarAvailability ? "Checking availability…" : "Use selected times in a reply",
                          systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || selected.count > 6 || model.isRunning || model.isCheckingCalendarAvailability)
                Text("Tern checks again before drafting. These times are not reserved.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.calendarChoiceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
    }
}
