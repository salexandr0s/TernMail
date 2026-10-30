import MailStore
import MessageContent
import SwiftUI

/// A quiet reading aid between the event cards and the original conversation.
struct ThreadSummaryView: View {
    let key: ThreadKey
    let detail: ThreadDetail
    let assistant: AssistantModel
    let isActive: Bool
    let onOpenSource: (AssistantSource) -> Void

    @State private var model = ThreadSummaryModel()
    @State private var loadedIdentity: LoadIdentity?
    @State private var isExpanded = false
    @State private var showsSettings = false
    @State private var attempt = 0
    @State private var handledAttempt = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private struct LoadIdentity: Equatable {
        let revision: String
        let access: Int
        let attempt: Int
        let isActive: Bool
    }

    private var identity: LoadIdentity {
        LoadIdentity(revision: ThreadSummaryModel.revision(for: detail),
            access: assistant.summaryAccessRevision, attempt: attempt, isActive: isActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            switch assistant.summaryAvailability(for: key) {
            case .ready:
                if loadedIdentity == identity, let report = model.report {
                    content(report)
                } else if loadedIdentity == identity, let error = model.errorMessage {
                    status(error, isLoading: false) {
                        Button("Retry") { attempt += 1 }.buttonStyle(.link)
                    }
                } else {
                    status("Summarizing…", isLoading: true)
                }
            case .loading:
                status("Getting summary ready…", isLoading: true)
            case .unavailable(let reason, let action):
                status(reason, isLoading: false) {
                    Button(action) { showsSettings = true }.buttonStyle(.link)
                }
            }
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reduceTransparency ? Tokens.Surface.muted : Tokens.ConversationHeader.surface,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(contrast == .increased ? Tokens.Surface.border : Tokens.ConversationHeader.border,
                    lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .task(id: identity) {
            let requested = identity
            loadedIdentity = nil
            isExpanded = false
            guard requested.isActive else { model.clear(); return }
            let forceRefresh = requested.attempt != handledAttempt
            handledAttempt = requested.attempt
            await model.load(key: key, revision: requested.revision, assistant: assistant,
                forceRefresh: forceRefresh, expectedMessageIDs: Set(detail.messages.map(\.id)))
            guard !Task.isCancelled, requested == identity else { return }
            loadedIdentity = requested
        }
        .onDisappear { model.clear(); loadedIdentity = nil }
        .sheet(isPresented: $showsSettings) {
            AssistantSettingsView(model: assistant, showsIntroduction: false, isSheet: true, showsMailScope: true)
        }
    }

    private var heading: some View {
        Label("AI summary", systemImage: "sparkles")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func content(_ report: ThreadSummaryReport) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s2) {
                heading
                Spacer(minLength: Tokens.Space.s2)
                Button {
                    withAnimation(reduceMotion ? nil : Tokens.Motion.standard()) { isExpanded.toggle() }
                } label: {
                    Label(isExpanded ? "Collapse" : "Details", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "Collapse AI summary" : "Show summary details")
                Menu {
                    Button("Refresh summary", systemImage: "arrow.clockwise") { attempt += 1 }
                    Button("Assistant settings", systemImage: "gearshape") { showsSettings = true }
                } label: {
                    Label("Summary options", systemImage: "ellipsis")
                        .labelStyle(.iconOnly).frame(width: Tokens.Space.s4, height: Tokens.Space.s4)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Summary options")
                .help("Summary options")
            }
            Text(report.summary.summary)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if report.hasPartialCoverage {
                Label("Based on partial message content", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Some messages, attachments, or longer passages could not be included.")
            }

            if isExpanded {
                if !report.summary.decisions.isEmpty {
                    sectionLabel("Decisions")
                    ForEach(report.summary.decisions.indices, id: \.self) { index in
                        let decision = report.summary.decisions[index]
                        evidenceRow(decision.text, ids: decision.sourceIDs, report: report)
                    }
                }
                if !report.summary.openTasks.isEmpty {
                    sectionLabel("Open tasks")
                    ForEach(report.summary.openTasks.indices, id: \.self) { index in
                        let task = report.summary.openTasks[index]
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            evidenceRow(task.description, ids: task.sourceIDs, report: report)
                            let metadata = [task.owner, task.dueDate.map { "Due \($0)" }].compactMap { $0 }
                            if !metadata.isEmpty {
                                Text(metadata.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                sourceMenu(ids: report.summary.sourceIDs, report: report, title: "Summary sources")
                    .padding(.top, Tokens.Space.s1)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.top, Tokens.Space.s1)
    }

    private func evidenceRow(_ text: String, ids: [String], report: ThreadSummaryReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            sourceMenu(ids: ids, report: report, title: "Sources", iconOnly: true)
        }
    }

    private func sourceMenu(ids: [String], report: ThreadSummaryReport, title: String, iconOnly: Bool = false) -> some View {
        Menu {
            ForEach(report.sources.filter { ids.contains($0.id) }) { source in
                Button(sourceLabel(source)) { onOpenSource(source) }
            }
        } label: {
            if iconOnly { Label(title, systemImage: "text.quote").labelStyle(.iconOnly) }
            else { Label(title, systemImage: "text.quote") }
        }
        .font(.caption)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .help("Open supporting messages")
    }

    private func sourceLabel(_ source: AssistantSource) -> String {
        guard let message = detail.messages.first(where: { $0.id == source.messageID }) else { return source.title }
        let sender = EmailAddress.parseList(message.record.sender).first
        let name = sender?.name ?? sender?.address ?? message.record.sender
        return "\(name) · \(message.record.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func status<Actions: View>(_ text: String, isLoading: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            heading
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                if isLoading { ProgressView().controlSize(.mini).accessibilityLabel(text) }
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions().font(.caption).fixedSize()
            }
        }
    }

    private func status(_ text: String, isLoading: Bool) -> some View {
        status(text, isLoading: isLoading) { EmptyView() }
    }
}
