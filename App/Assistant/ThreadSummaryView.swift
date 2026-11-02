import MailStore
import MessageContent
import SwiftUI

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
                        onSettings: { showsSettings = true })
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

    @State private var isExpanded = false
    @State private var fullTextHeight: CGFloat = 0
    @State private var collapsedTextHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasDetails: Bool {
        !report.summary.decisions.isEmpty || !report.summary.openTasks.isEmpty
            || fullTextHeight > collapsedTextHeight + Tokens.Border.hairline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s2) {
                SummaryHeading()
                if isRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing summary")
                }
                Spacer(minLength: Tokens.Space.s2)
                sourceMenu(sources: report.sources, title: "Sources", accessibilityID: "summary-sources")
                Menu {
                    Button("Refresh Summary", systemImage: "arrow.clockwise", action: onRefresh)
                        .disabled(isRefreshing)
                    Button("Assistant Settings…", systemImage: "gearshape", action: onSettings)
                } label: {
                    Label("Summary options", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Space.s6)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Summary options")
                .accessibilityIdentifier("summary-options")
                .help("Summary options")
            }

            summaryText
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .background(alignment: .topLeading) {
                    // Measure both variants at the actual reading width. An empty Details
                    // control is unnecessary, but clipped summaries must remain expandable.
                    summaryText.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedTextHeight = $0 }
                        .hidden().accessibilityHidden(true)
                    summaryText.fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullTextHeight = $0 }
                        .hidden().accessibilityHidden(true)
                }

            if report.hasPartialCoverage {
                Label("Based on partial message content", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Some messages, attachments, or longer passages could not be included.")
            }

            if let refreshError {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    Text(refreshError).foregroundStyle(.secondary)
                    Button("Retry", action: onRefresh).buttonStyle(.link)
                }
                .font(.caption)
            }

            if isExpanded {
                details
            }
            if hasDetails || isExpanded {
                Button {
                    withAnimation(reduceMotion ? nil : Tokens.Motion.standard()) { isExpanded.toggle() }
                } label: {
                    Label(isExpanded ? "Show less" : "Show details", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .padding(.vertical, Tokens.Space.s0_5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "Show less summary detail" : "Show summary details")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("summary-details")
            }
        }
        .modifier(SummarySurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-summary")
    }

    private var summaryText: some View {
        Text(report.summary.summary)
            .font(.callout)
            .frame(maxWidth: Tokens.Assistant.contentWidth, alignment: .leading)
    }

    @ViewBuilder private var details: some View {
        if !report.summary.decisions.isEmpty || !report.summary.openTasks.isEmpty {
            Divider().padding(.vertical, Tokens.Space.s1)
        }
        if !report.summary.decisions.isEmpty {
            sectionLabel("Decisions")
            ForEach(report.summary.decisions.indices, id: \.self) { index in
                let decision = report.summary.decisions[index]
                evidenceRow(decision.text, ids: decision.sourceIDs, accessibilityID: "summary-decision-sources-\(index)")
            }
        }
        if !report.summary.openTasks.isEmpty {
            sectionLabel("Open tasks")
            ForEach(report.summary.openTasks.indices, id: \.self) { index in
                let task = report.summary.openTasks[index]
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    evidenceRow(task.description, ids: task.sourceIDs, accessibilityID: "summary-task-sources-\(index)")
                    let metadata = [task.owner, task.dueDate.map { "Due \($0)" }].compactMap { $0 }
                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    private func evidenceRow(_ text: String, ids: [String], accessibilityID: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            sourceMenu(sources: report.sources.filter { ids.contains($0.id) }, title: "Sources", iconOnly: true,
                accessibilityID: accessibilityID)
        }
    }

    @ViewBuilder private func sourceMenu(sources: [AssistantSource], title: String, iconOnly: Bool = false,
                                        accessibilityID: String) -> some View {
        if !sources.isEmpty {
            Menu {
                ForEach(sources) { source in
                    Button(sourceLabel(source)) { onOpenSource(source) }
                }
            } label: {
                if iconOnly { Label(title, systemImage: "text.quote").labelStyle(.iconOnly) }
                else { Text(title) }
            }
            .font(.caption)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(iconOnly ? "Sources for this item" : "Summary sources")
            .accessibilityIdentifier(accessibilityID)
            .help("Open supporting messages")
        }
    }

    private func sourceLabel(_ source: AssistantSource) -> String {
        guard let message = detail.messages.first(where: { $0.id == source.messageID }) else { return source.title }
        let sender = EmailAddress.parseList(message.record.sender).first
        let name = sender?.name ?? sender?.address ?? message.record.sender
        return "\(name) · \(message.record.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct SummaryHeading: View {
    var body: some View {
        Label("AI summary", systemImage: "sparkles")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
            .padding(.horizontal, Tokens.Space.s3)
            .padding(.vertical, Tokens.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(reduceTransparency ? Tokens.Surface.muted : Tokens.ConversationHeader.surface,
                in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline)
                        .allowsHitTesting(false)
                }
            }
    }
}
