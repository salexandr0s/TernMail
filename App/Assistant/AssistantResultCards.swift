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
    @State private var showsAllTasks = false
    @State private var showsAllEvents = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.sectionGap) {
            if !message.taskResults.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    sectionTitle("Tasks from mail", symbol: "checklist", count: message.taskResults.count)
                    ForEach(showsAllTasks ? message.taskResults : Array(message.taskResults.prefix(Tokens.AssistantFormatting.resultPreviewCount))) { task in
                        AssistantTaskCard(task: task,
                            state: model.taskDestinationModel?.creationState(for: task.request) ?? .idle,
                            isEnabled: model.canUseTaskResult(task) && model.taskDestinationModel != nil,
                            onReview: { reviewingTask = task }, onOpenSource: onOpenSource)
                            .ternTransition(.disclosure)
                    }
                    if message.taskResults.count > Tokens.AssistantFormatting.resultPreviewCount {
                        expansionButton(isExpanded: $showsAllTasks,
                            total: message.taskResults.count, kind: "tasks")
                    }
                }
                .ternAnimation(value: showsAllTasks, duration: Tokens.Motion.slow)
            }
            if !message.eventResults.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    sectionTitle("Events", symbol: "calendar", count: message.eventResults.count)
                    ForEach(showsAllEvents ? message.eventResults : Array(message.eventResults.prefix(Tokens.AssistantFormatting.resultPreviewCount))) { event in
                        AssistantEventCard(event: event, isEnabled: model.canUseEventResult(event),
                            isReviewing: reviewingEventID == event.id, error: eventErrors[event.id],
                            onReview: { review(event) }, onOpenSource: onOpenSource)
                            .ternTransition(.disclosure)
                    }
                    if message.eventResults.count > Tokens.AssistantFormatting.resultPreviewCount {
                        expansionButton(isExpanded: $showsAllEvents,
                            total: message.eventResults.count, kind: "events")
                    }
                }
                .ternAnimation(value: showsAllEvents, duration: Tokens.Motion.slow)
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
        .font(Tokens.AssistantFormatting.titleFont)
        .accessibilityAddTraits(.isHeader)
    }

    private func expansionButton(isExpanded: Binding<Bool>, total: Int, kind: String) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            Text(isExpanded.wrappedValue ? "Show fewer \(kind)" : "Show all \(total) \(kind)")
                .frame(minHeight: Tokens.Space.s6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .font(Tokens.AssistantFormatting.metadataFont)
        .controlSize(.small)
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
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
        VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
            Text(task.title).font(Tokens.AssistantFormatting.titleFont)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: Tokens.Space.s2) {
                Label(dueLabel, systemImage: "calendar")
                if let owner = task.owner { Label(owner, systemImage: "person") }
            }
            .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
            AssistantResultFooter(source: task.source, evidence: task.evidence, notes: task.notes, onOpen: onOpenSource) {
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
        }
        .padding(Tokens.AssistantFormatting.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
        .ternOutline(radius: Tokens.AssistantFormatting.cornerRadius)
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
        let notes = event.event.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsStatedTime = presentation.start == nil
        VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                CalendarDateTile(month: presentation.month, day: presentation.day)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(event.title).font(Tokens.AssistantFormatting.titleFont)
                    Text(presentation.dateLine).font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                    if let original = presentation.originalTimeZoneLine {
                        Text(original).font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let location = presentation.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsStatedTime, let notes, !notes.isEmpty {
                Text(notes).font(Tokens.AssistantFormatting.supportingFont).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(event.uncertainties.filter { $0 != presentation.dateLine }, id: \.self) { warning in
                Label(warning, systemImage: "questionmark.circle")
                    .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AssistantResultFooter(source: event.source, evidence: event.evidence,
                                  notes: showsStatedTime ? nil : notes, onOpen: onOpenSource) {
                Button(action: onReview) {
                    Label(event.isExistingEvent ? "Open in Calendar" : "Add to Calendar",
                          systemImage: event.isExistingEvent ? "calendar" : "calendar.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!isEnabled || isReviewing || (!event.isExistingEvent && !event.canAddToCalendar))
                .help(event.isExistingEvent ? "Open the existing calendar event" : "Review event details before saving")
                if isReviewing { ProgressView().controlSize(.mini) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(Tokens.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Tokens.AssistantFormatting.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
        .ternOutline(radius: Tokens.AssistantFormatting.cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Event: \(event.title)")
    }
}

private struct AssistantResultFooter<Action: View>: View {
    let source: AssistantSource
    let evidence: String?
    let notes: String?
    let onOpen: (AssistantSource) -> Void
    let action: Action
    @State private var showsDetails = false

    init(source: AssistantSource, evidence: String?, notes: String?, onOpen: @escaping (AssistantSource) -> Void,
         @ViewBuilder action: () -> Action) {
        self.source = source
        self.evidence = evidence
        self.notes = notes
        self.onOpen = onOpen
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    sourceControls.fixedSize()
                    Spacer(minLength: Tokens.Space.s2)
                    HStack(spacing: Tokens.Space.s1) { action }.fixedSize()
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    sourceControls
                    HStack(spacing: Tokens.Space.s1) { action }
                }
            }
            .controlSize(.small)
            if showsDetails {
                VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
                    if let notes, !notes.isEmpty {
                        Text(notes).font(Tokens.AssistantFormatting.supportingFont)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let evidence, !evidence.isEmpty {
                        Text("Source excerpt").font(Tokens.AssistantFormatting.metadataFont.weight(.medium)).foregroundStyle(.secondary)
                        Text(evidence).font(Tokens.AssistantFormatting.supportingFont).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .ternTransition(.disclosure)
            }
        }
        .font(Tokens.AssistantFormatting.metadataFont)
        .ternAnimation(value: showsDetails)
    }

    private var sourceControls: some View {
        HStack(spacing: Tokens.Space.s2) {
            Button { onOpen(source) } label: {
                Label("Source", systemImage: source.systemImage)
                    .frame(minHeight: Tokens.Space.s6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.link).help("Open source: \(source.title)")
            .accessibilityLabel(source.title.isEmpty ? "Open source" : "Open source: \(source.title)")
            if notes?.isEmpty == false || evidence?.isEmpty == false {
                Button { showsDetails.toggle() } label: {
                    Label("Details", systemImage: showsDetails ? "chevron.down" : "chevron.right")
                        .frame(minHeight: Tokens.Space.s6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(showsDetails ? "Hide details and source excerpt" : "Show details and source excerpt")
                .accessibilityLabel("Source excerpt and details")
                .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
            }
        }
    }
}
