import MailStore
import MessageContent
import SwiftUI
import TernAI

/// A reading aid between the event cards and the original conversation.
struct ThreadSummaryView: View {
    let key: ThreadKey
    let detail: ThreadDetail
    let assistant: AssistantModel
    let isActive: Bool
    let onOpenSource: (AssistantSource) -> Void

    @State private var model = ThreadSummaryModel()
    @State private var loadedIdentity: LoadIdentity?
    @State private var displayed: ThreadSummaryDisplayState?
    @State private var showsSettings = false
    @State private var attempt = 0
    @State private var handledAttempt = 0
    @Environment(AppModel.self) private var app

    private struct LoadIdentity: Equatable {
        let source: ThreadSummaryDisplayState.Source
        let attempt: Int
        let isActive: Bool
    }

    private var identity: LoadIdentity {
        LoadIdentity(source: .init(revision: ThreadSummaryModel.revision(for: detail),
            access: assistant.summaryAccessRevision), attempt: attempt, isActive: isActive)
    }

    var body: some View {
        let availability = assistant.summaryAvailability(for: key)
        if Self.isOffered(availability, isRestoring: assistant.connection.isRestoring) {
            // Keep task and disappearance ownership stable when loading gives way
            // to content; Group would distribute those modifiers to each child.
            VStack(alignment: .leading, spacing: 0) {
                if availability == .ready, isActive, let report = displayed?.report(for: identity.source) {
                    ThreadSummaryContent(report: report, detail: detail,
                        isRefreshing: loadedIdentity != identity,
                        refreshError: loadedIdentity == identity ? model.errorMessage : nil,
                        onOpenSource: onOpenSource, onRefresh: { attempt += 1 },
                        onSettings: { showsSettings = true }, tasks: app.tasks,
                        taskAccountEmail: app.mailbox?.account(id: detail.thread.accountID)?.account.email,
                        onAddTask: { request in
                            app.showTasks()
                            Task { await app.tasks.add(request) }
                        })
                        .id(identity.source)
                } else {
                    let error = loadedIdentity == identity ? model.errorMessage : nil
                    SummaryStatus(text: error ?? (availability == .loading ? "Getting summary ready…" : "Summarizing…"),
                        isLoading: error == nil, onRetry: error == nil ? nil : { attempt += 1 })
                        .modifier(SummarySurface())
                }
            }
            .task(id: identity) {
                let requested = identity
                loadedIdentity = nil
                if displayed?.source != requested.source { displayed = nil }
                guard requested.isActive else { model.clear(); displayed = nil; return }
                let forceRefresh = requested.attempt != handledAttempt
                handledAttempt = requested.attempt
                await model.load(key: key, revision: requested.source.revision, assistant: assistant,
                    forceRefresh: forceRefresh, expectedMessageIDs: Set(detail.messages.map(\.id)))
                guard !Task.isCancelled, requested == identity else { return }
                if let report = model.report {
                    displayed = .init(source: requested.source, value: report)
                }
                loadedIdentity = requested
            }
            .onDisappear { model.clear(); loadedIdentity = nil; displayed = nil }
            .sheet(isPresented: $showsSettings) {
                AssistantSettingsView(model: assistant, isSheet: true, showsMailScope: true)
            }
        }
    }

    private static func isOffered(_ availability: ThreadSummaryAvailability, isRestoring: Bool) -> Bool {
        switch availability {
        case .ready: true
        case .loading: !isRestoring
        case .unavailable: false
        }
    }
}

/// Retain the visible summary during Refresh, but never across content or access changes.
struct ThreadSummaryDisplayState {
    struct Source: Hashable {
        let revision: String
        let access: Int
    }

    let source: Source
    let value: ThreadSummaryReport

    func report(for current: Source) -> ThreadSummaryReport? {
        source == current ? value : nil
    }
}

/// The same summary presentation is used by the reader and native audit fixtures.
struct ThreadSummaryContent: View {
    let report: ThreadSummaryReport
    let detail: ThreadDetail
    var isRefreshing = false
    var refreshError: String? = nil
    let onOpenSource: (AssistantSource) -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    var tasks: GoogleTasksModel? = nil
    var taskAccountEmail: String? = nil
    var onAddTask: ((TaskCreationRequest) -> Void)? = nil

    private enum Section: String, Hashable { case tasks, decisions }

    @State private var isExpanded = true
    @State private var isOverviewExpanded = false
    @State private var expandedSections: Set<Section> = []
    @State private var fullTextHeight: CGFloat = 0
    @State private var collapsedTextHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private var hasClippedOverview: Bool {
        fullTextHeight > collapsedTextHeight + Tokens.Border.hairline
    }

    private var availableSections: Set<Section> {
        var sections: Set<Section> = []
        if !report.summary.openTasks.isEmpty { sections.insert(.tasks) }
        if !report.summary.decisions.isEmpty { sections.insert(.decisions) }
        return sections
    }

    private var isFullyExpanded: Bool {
        isExpanded && availableSections.isSubset(of: expandedSections)
            && (!hasClippedOverview || isOverviewExpanded)
    }

    private var countsDescription: String {
        let tasks = report.summary.openTasks.count
        let decisions = report.summary.decisions.count
        let counts = [
            tasks > 0 ? "\(tasks) open \(tasks == 1 ? "task" : "tasks")" : nil,
            decisions > 0 ? "\(decisions) \(decisions == 1 ? "decision" : "decisions")" : nil,
        ].compactMap { $0 }
        return counts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    overview
                    if report.hasPartialCoverage {
                        Label("Based on partial message content", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Some messages, attachments, or longer passages could not be included.")
                    }
                    details
                }
                .ternTransition(.disclosure)
            }

            if let refreshError {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    Text(refreshError).foregroundStyle(.secondary)
                    Button("Retry", action: onRefresh).buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .modifier(SummarySurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-summary")
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s1) {
            Button {
                animate { isExpanded.toggle() }
            } label: {
                HStack(spacing: Tokens.Space.s1_5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    SummaryHeading().fixedSize()
                    if !isExpanded, !countsDescription.isEmpty {
                        Text(countsDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: Tokens.Space.s6, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Minimise AI summary" : "Expand AI summary")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("summary-disclosure")
            .accessibilityHint(countsDescription)
            .help(isExpanded ? "Minimise summary" : "Expand summary")

            if isRefreshing { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing summary") }
            if !isExpanded, report.hasPartialCoverage {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .accessibilityLabel("Based on partial message content")
                    .help("Based on partial message content")
            }
            if !availableSections.isEmpty || hasClippedOverview {
                Button {
                    animate {
                        if isFullyExpanded {
                            expandedSections = []
                            isOverviewExpanded = false
                        } else {
                            isExpanded = true
                            expandedSections = availableSections
                            isOverviewExpanded = true
                        }
                    }
                } label: {
                    Label(isFullyExpanded ? "Collapse all sections" : "Expand all sections",
                          systemImage: isFullyExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityIdentifier("summary-expand-all")
                .help(isFullyExpanded ? "Collapse all sections" : "Expand all sections")
                .ternHover(radius: Tokens.Radius.sm)
            }
            sourceMenu(sources: report.sources, title: "Summary sources", accessibilityID: "summary-sources")
            Menu {
                Button("Refresh Summary", systemImage: "arrow.clockwise", action: onRefresh).disabled(isRefreshing)
                Button("Assistant Settings…", systemImage: "gearshape", action: onSettings)
            } label: {
                Label("Summary options", systemImage: "ellipsis").labelStyle(.iconOnly)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Summary options").accessibilityIdentifier("summary-options")
            .help("Summary options")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            summaryText
                .lineLimit(isOverviewExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("summary-overview")
                .background(alignment: .topLeading) {
                    summaryText.lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedTextHeight = $0 }
                        .hidden().accessibilityHidden(true)
                    summaryText.fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullTextHeight = $0 }
                        .hidden().accessibilityHidden(true)
                }
            if hasClippedOverview {
                Button {
                    animate { isOverviewExpanded.toggle() }
                } label: {
                    HStack(spacing: Tokens.Space.s1) {
                        Text(isOverviewExpanded ? "Show less" : "Read more")
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.medium))
                            .rotationEffect(.degrees(isOverviewExpanded ? 180 : 0))
                    }
                    .frame(minHeight: Tokens.Space.s6, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityLabel(isOverviewExpanded ? "Collapse summary overview" : "Read full summary overview")
                .accessibilityValue(isOverviewExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("summary-details")
            }
        }
    }

    private func animate(_ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : Tokens.Motion.standard(duration: Tokens.Motion.slow), changes)
    }

    private var summaryText: some View {
        Text(report.summary.summary)
            .font(.callout)
            .lineSpacing(Tokens.Space.s0_5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var details: some View {
        if !report.summary.openTasks.isEmpty {
            disclosureSection(.tasks, title: "Open tasks", symbol: "checklist", count: report.summary.openTasks.count) {
                ForEach(report.summary.openTasks.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    taskRow(report.summary.openTasks[index], index: index)
                }
            }
        }
        if !report.summary.decisions.isEmpty {
            disclosureSection(.decisions, title: "Decisions", symbol: "checkmark.bubble", count: report.summary.decisions.count) {
                ForEach(report.summary.decisions.indices, id: \.self) { index in
                    let decision = report.summary.decisions[index]
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: Tokens.Space.s2) {
                        Text(decision.text).font(.callout)
                            .lineSpacing(Tokens.Space.s0_5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Tokens.Space.s1)
                        sourceMenu(sources: report.sources.filter { decision.sourceIDs.contains($0.id) },
                            title: "Sources for decision \(index + 1)",
                            accessibilityID: "summary-decision-sources-\(index)")
                    }
                    .padding(.vertical, Tokens.Space.s2)
                }
            }
        }
    }

    private func disclosureSection<Content: View>(_ section: Section, title: String, symbol: String, count: Int,
                                                   @ViewBuilder content: () -> Content) -> some View {
        let isOpen = expandedSections.contains(section)
        return VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, Tokens.Space.s2)
            Button {
                animate {
                    if isOpen { expandedSections.remove(section) }
                    else { expandedSections.insert(section) }
                }
            } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: symbol)
                        .font(.caption)
                        .frame(width: Tokens.Space.s4)
                        .accessibilityHidden(true)
                    Text(title).font(.caption.weight(.medium))
                    Text("\(count)").font(.caption2.monospacedDigit())
                        .padding(.horizontal, Tokens.Space.s1_5)
                        .padding(.vertical, Tokens.Space.s0_5)
                        .background(Color.primary.opacity(Tokens.Opacity.hover), in: Capsule())
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.medium))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: Tokens.Space.s6)
                }
                .frame(maxWidth: .infinity, minHeight: Tokens.Space.s6, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("\(isOpen ? "Collapse" : "Expand") \(title), \(count)")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("summary-\(section.rawValue)-toggle")
            .ternHover(radius: Tokens.Radius.sm)
            if isOpen {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .padding(.top, Tokens.Space.s1)
                    .ternTransition(.disclosure)
            }
        }
    }

    private func taskRow(_ task: AssistantSummary.OpenTask, index: Int) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                Text(task.description).font(.callout)
                    .lineSpacing(Tokens.Space.s0_5)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, Tokens.Space.s1)
                if task.owner != nil || task.dueDate != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.s3) { taskMetadata(task) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) { taskMetadata(task) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Tokens.Space.s1) {
                sourceMenu(sources: report.sources.filter { task.sourceIDs.contains($0.id) },
                    title: "Sources for task \(index + 1)",
                    accessibilityID: "summary-task-sources-\(index)")
                if let tasks, let onAddTask {
                    EmailTaskAddButton(request: EmailTaskRequest.suggestion(task, report: report,
                        detail: detail, accountEmail: taskAccountEmail), model: tasks, onAdd: onAddTask, isCompact: true)
                        .accessibilityIdentifier("summary-task-add-\(index)")
                }
            }
        }
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary-task-\(index)")
    }

    @ViewBuilder private func taskMetadata(_ task: AssistantSummary.OpenTask) -> some View {
        if let owner = task.owner {
            Label(owner, systemImage: "person")
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityLabel("Owner: \(owner)")
        }
        if let date = task.dueDate {
            Label("Due \(SummaryDueDate.formatted(date, locale: locale))", systemImage: "calendar")
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .help(date)
        }
    }

    @ViewBuilder private func sourceMenu(sources: [AssistantSource], title: String,
                                        accessibilityID: String) -> some View {
        if !sources.isEmpty {
            Menu {
                ForEach(sources) { source in
                    Button(sourceLabel(source)) { onOpenSource(source) }
                }
            } label: {
                Label(title, systemImage: "text.quote").labelStyle(.iconOnly)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .contentShape(Rectangle())
            }
            .font(.caption)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityIdentifier(accessibilityID)
            .help("Open supporting messages")
            .ternHover(radius: Tokens.Radius.sm)
        }
    }

    private func sourceLabel(_ source: AssistantSource) -> String {
        guard let message = detail.messages.first(where: { $0.id == source.messageID }) else { return source.title }
        let sender = EmailAddress.parseList(message.record.sender).first
        let name = sender?.name ?? sender?.address ?? message.record.sender
        return "\(name) · \(message.record.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// A due date is a calendar day, not an instant in the reader's time zone.
enum SummaryDueDate {
    static func formatted(_ value: String, locale: Locale) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        guard let date = parser.date(from: value), parser.string(from: date) == value else { return value }
        let output = DateFormatter()
        output.locale = locale
        output.calendar = Calendar(identifier: .gregorian)
        output.timeZone = TimeZone(secondsFromGMT: 0)
        output.dateStyle = .medium
        output.timeStyle = .none
        return output.string(from: date)
    }
}

private struct SummaryHeading: View {
    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .accessibilityHidden(true)
            Text("AI summary").font(.caption.weight(.semibold))
        }
    }
}

private struct SummaryStatus: View {
    let text: String
    let isLoading: Bool
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            SummaryHeading()
            if isLoading { ProgressView().controlSize(.mini).accessibilityLabel(text) }
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry { Button("Retry", action: onRetry).font(.caption).buttonStyle(.link) }
        }
        .frame(minHeight: Tokens.Space.s6, alignment: .leading)
    }
}

private struct SummarySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(Tokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(reduceTransparency ? Tokens.Surface.muted : Tokens.ConversationHeader.surface,
                in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .strokeBorder(contrast == .increased ? Tokens.Surface.border : Tokens.ConversationHeader.border,
                        lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
    }
}
