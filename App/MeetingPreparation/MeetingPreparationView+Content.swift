import MailStore
import SwiftUI
import TernAI

struct MeetingPreparationCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
        .accessibilityElement(children: .contain)
    }
}

struct MeetingPreparationSourceRowView: View {
    let source: MeetingPreparationSourceRow
    let accountName: String
    let actionTitle: String
    let actionSymbol: String
    let open: () -> Void
    let act: () -> Void
    var isActionDisabled = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Button(action: open) {
                    Text(source.title.isEmpty ? "Untitled conversation" : source.title)
                        .font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open conversation: \(source.title)")
                .accessibilityIdentifier("meeting-source-open-\(source.id)")
                Text(accountName).font(.caption).foregroundStyle(.secondary)
                Text(source.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = source.unavailableMessage {
                    Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Tokens.Status.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, systemImage: actionSymbol, action: act)
                .controlSize(.small)
                .disabled(isActionDisabled)
                .accessibilityLabel("\(actionTitle) conversation: \(source.title)")
                .accessibilityIdentifier("meeting-source-action-\(source.id)")
        }
        .padding(.vertical, Tokens.Space.s1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-source-\(source.id)")
    }
}

struct MeetingPreparationThreadSection: View {
    let section: MeetingPreparationSection
    let accountName: String
    let canTrack: Bool
    let openSource: (AssistantSource) -> Void
    let track: (MeetingPreparationTaskSuggestion) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        MeetingPreparationCard(title: section.candidate.title.isEmpty ? "Untitled conversation" : section.candidate.title,
            symbol: "text.bubble") {
            Text("\(accountName) · \(section.candidate.reason.explanation)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(section.report.summary.summary).font(.callout)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityIdentifier("meeting-summary-\(section.id)")
            citations(section.report.sources.filter { section.report.summary.sourceIDs.contains($0.id) }, kind: "summary")
            if section.report.hasPartialCoverage {
                Label("Based on partial message content.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !section.report.summary.decisions.isEmpty {
                Divider()
                Text("Decisions").font(.subheadline.weight(.semibold))
                ForEach(Array(section.report.summary.decisions.enumerated()), id: \.offset) { index, decision in
                    VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                        Text(decision.text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        citations(section.report.sources.filter { decision.sourceIDs.contains($0.id) }, kind: "decision-\(index)")
                    }
                    .accessibilityElement(children: .contain)
                }
            }

            if !section.suggestions.isEmpty {
                Divider()
                Text("Suggested work").font(.subheadline.weight(.semibold))
                Text("Review a suggestion before tracking it.").font(.caption).foregroundStyle(.secondary)
                ForEach(section.suggestions) { suggestion in
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Text(suggestion.task.description).font(.callout)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        FlowLayout(spacing: Tokens.Space.s3) {
                            if let owner = suggestion.task.owner { Label(owner, systemImage: "person") }
                            if let due = suggestion.task.dueDate {
                                Label("Due \(SummaryDueDate.formatted(due, locale: locale))", systemImage: "calendar")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        citations(suggestion.sources, kind: "task-\(suggestion.id)")
                        Button("Track Follow-up…", systemImage: "clock.badge.checkmark") { track(suggestion) }
                            .controlSize(.small).disabled(!canTrack)
                            .accessibilityIdentifier("meeting-track-\(suggestion.id)")
                    }
                    .padding(.vertical, Tokens.Space.s1)
                    .accessibilityElement(children: .contain)
                }
            }
            if section.suppressedSuggestionCount > 0 {
                Label("Saved follow-ups already cover source messages used by other suggestions. Those suggestions are hidden; you can track separate work from the original email.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("meeting-thread-\(section.id)")
    }

    private func citations(_ sources: [AssistantSource], kind: String) -> some View {
        MeetingPreparationCitations(sources: sources, prefix: "\(section.id)-\(kind)", open: openSource)
    }
}

/// Holds the place of a conversation's card until its summary arrives.
struct MeetingPreparationPendingSection: View {
    let candidate: MeetingPreparationCandidate
    let accountName: String

    var body: some View {
        MeetingPreparationCard(title: candidate.title.isEmpty ? "Untitled conversation" : candidate.title,
            symbol: "text.bubble") {
            Text("\(accountName) · \(candidate.reason.explanation)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Preparing summary…").font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("meeting-thread-pending-\(candidate.thread.accountID.utf8.count):\(candidate.thread.accountID)\(candidate.thread.threadID)")
    }
}

struct MeetingPreparationCitations: View {
    let sources: [AssistantSource]
    let prefix: String
    let open: (AssistantSource) -> Void

    var body: some View {
        FlowLayout(spacing: Tokens.Space.s3) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                Button { open(source) } label: {
                    Label(sources.count == 1 ? "Open source" : "Source \(index + 1)", systemImage: "text.quote")
                }
                .buttonStyle(.link).font(.caption)
                .help(source.title)
                .accessibilityLabel("Open source: \(source.title)")
                .accessibilityIdentifier("meeting-citation-\(prefix)-\(index)")
            }
        }
    }
}

struct MeetingPreparationTrackedRow: View {
    let entry: CommitmentEntry
    let accountName: String
    let open: () -> Void

    private var status: String {
        switch entry.record.status {
        case .open: "Open"
        case .completed: "Completed"
        case .dismissed: "Dismissed"
        }
    }

    private var symbol: String {
        switch entry.record.status {
        case .open: "circle"
        case .completed: "checkmark.circle"
        case .dismissed: "minus.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(entry.record.title).font(.callout.weight(.medium))
                .strikethrough(entry.record.status == .completed)
                .foregroundStyle(entry.record.status == .open ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            FlowLayout(spacing: Tokens.Space.s3) {
                Label(status, systemImage: symbol)
                Text(accountName)
                if let owner = entry.record.ownerName ?? entry.record.ownerEmail { Label(owner, systemImage: "person") }
                if let due = entry.record.dueAt { Label("Due \(FollowUpSchedule.deadlineText(due))", systemImage: "calendar") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Button("Open Source Email", systemImage: "envelope", action: open).buttonStyle(.link).font(.caption)
                .accessibilityIdentifier("meeting-tracked-source-\(entry.record.id)")
        }
        .padding(.vertical, Tokens.Space.s1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-tracked-\(entry.record.id)")
    }
}
