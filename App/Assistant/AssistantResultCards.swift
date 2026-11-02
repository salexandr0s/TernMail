import GmailAPI
import SwiftUI

/// Cards hold validated results. Each Add action opens an editable review.
struct AssistantResultCards: View {
    let message: AssistantMessage
    let model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    @State private var reviewingTask: AssistantTaskResult?
    @State private var reviewingEventID: String?
    @State private var eventErrors: [String: String] = [:]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            if !message.taskResults.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    sectionTitle("Tasks from mail", symbol: "checklist", count: message.taskResults.count)
                    ForEach(message.taskResults) { task in
                        AssistantTaskCard(task: task,
                            state: model.taskDestinationModel?.creationState(for: task.request) ?? .idle,
                            isEnabled: model.canUseTaskResult(task) && model.taskDestinationModel != nil,
                            onReview: { reviewingTask = task }, onOpenSource: onOpenSource)
                    }
                }
            }
            if !message.eventResults.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    sectionTitle("Events", symbol: "calendar", count: message.eventResults.count)
                    ForEach(message.eventResults) { event in
                        AssistantEventCard(event: event, isEnabled: model.canUseEventResult(event),
                            isReviewing: reviewingEventID == event.id, error: eventErrors[event.id],
                            onReview: { review(event) }, onOpenSource: onOpenSource)
                    }
                }
            }
        }
        .sheet(item: $reviewingTask) { task in
            if let destination = model.taskDestinationModel {
                AssistantTaskReview(request: task.request, model: destination,
                    isAuthorized: { model.canUseTaskResult(task) })
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            Label(title, systemImage: symbol)
            Spacer(minLength: Tokens.Space.s2)
            Text("\(count)").monospacedDigit()
        }
        .font(.callout.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
    }

    private func review(_ event: AssistantEventResult) {
        guard reviewingEventID == nil else { return }
        reviewingEventID = event.id
        eventErrors[event.id] = nil
        Task {
            defer { reviewingEventID = nil }
            do {
                try await model.reviewEventResult(event)
                openWindow(id: RootView.sceneID)
            } catch {
                eventErrors[event.id] = (error as? LocalizedError)?.errorDescription
                    ?? "The event couldn't be opened. Try again."
            }
        }
    }
}

struct AssistantTaskCard: View {
    let task: AssistantTaskResult
    let state: TaskCreationState
    let isEnabled: Bool
    let onReview: () -> Void
    let onOpenSource: (AssistantSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text(task.title).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Label(dueLabel, systemImage: "calendar")
                if let owner = task.owner { Label(owner, systemImage: "person") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !task.notes.isEmpty {
                Text(task.notes).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            AssistantResultEvidence(source: task.source, evidence: task.evidence, onOpen: onOpenSource)
            HStack(spacing: Tokens.Space.s2) {
                if state == .added {
                    Label("Added to Tasks", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Status.success)
                } else {
                    Button(action: onReview) {
                        Label(state == .uncertain ? "Check saved task" : "Add to Tasks", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isEnabled || state == .adding)
                    .help("Review the title, due date and destination list before adding")
                    if state == .adding { ProgressView().controlSize(.mini) }
                }
            }
            .font(.caption)
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task: \(task.title)")
    }

    private var dueLabel: String {
        guard let day = task.dueDate, let date = GoogleTaskDateCoding.date(day) else { return "No due date stated" }
        return "Due \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct AssistantEventCard: View {
    let event: AssistantEventResult
    let isEnabled: Bool
    let isReviewing: Bool
    let error: String?
    let onReview: () -> Void
    let onOpenSource: (AssistantSource) -> Void

    var body: some View {
        let presentation = event.presentation()
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                VStack(spacing: Tokens.Space.s0_5) {
                    if let month = presentation.month, let day = presentation.day {
                        Text(month).font(.caption2.weight(.semibold))
                        Text(day).font(.title2.weight(.semibold)).monospacedDigit()
                    } else {
                        Image(systemName: "calendar").font(.title2)
                    }
                }
                .foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(event.title).font(.callout.weight(.semibold))
                    Text(presentation.dateLine).font(.caption).foregroundStyle(.secondary)
                    if let original = presentation.originalTimeZoneLine {
                        Text(original).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let location = presentation.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(event.uncertainties, id: \.self) { warning in
                Label(warning, systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AssistantResultEvidence(source: event.source, evidence: event.evidence, onOpen: onOpenSource)
            HStack(spacing: Tokens.Space.s2) {
                Button(action: onReview) {
                    Label(event.isExistingEvent ? "Open in Calendar" : "Add to Calendar",
                          systemImage: event.isExistingEvent ? "calendar" : "calendar.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!isEnabled || isReviewing || (!event.isExistingEvent && !event.canAddToCalendar))
                .help(event.isExistingEvent ? "Open the existing calendar event" : "Review event details before saving")
                if isReviewing { ProgressView().controlSize(.mini) }
            }
            .font(.caption)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Tokens.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Event: \(event.title)")
    }
}

private struct AssistantResultEvidence: View {
    let source: AssistantSource
    let evidence: String?
    let onOpen: (AssistantSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Button { onOpen(source) } label: {
                Label(source.title.isEmpty ? "Open source" : source.title, systemImage: source.systemImage)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.link).help("Open source: \(source.title)")
            if let evidence, !evidence.isEmpty {
                DisclosureGroup("Source excerpt") {
                    Text(evidence).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Tokens.Space.s1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
