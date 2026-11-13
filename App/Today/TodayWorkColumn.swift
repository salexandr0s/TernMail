import MailStore
import SwiftUI

/// Tasks, commitments, follow-ups and unread mail, in that order. The cards
/// stack in plain stacks; only the commitment and follow-up rows are lazy.
struct TodayWorkColumn: View {
    let model: TodayModel
    let dashboard: TodayDashboardModel
    let automaticFollowUps: AutomaticFollowUpCoordinator?
    let visibility: TodayRowVisibility
    let query: String
    @Binding var snoozeRequest: TodaySnoozeRequest?

    var body: some View {
        let presentation = model.presentation, owed = presentation.owed
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            TodayTasksPanel(dashboard: dashboard, query: query)
            if !owed.isEmpty {
                TodayDashboardSection(title: "I owe", symbol: "person.crop.circle", count: owed.count,
                                      countLabel: "commitments shown") {
                    LazyVStack(spacing: 0) {
                        ForEach(owed) { row in
                            TodayPresentedRow(row: row, snooze: presentation.snooze, model: model,
                                visibility: visibility, snoozeRequest: $snoozeRequest)
                            if row.id != owed.last?.id { Divider() }
                        }
                    }
                    .ternAnimation(value: owed.map(\.id))
                }
                .accessibilityIdentifier("today-owed")
                .ternTransition(.fade)
            }
            TodayFollowUpsSection(model: model, automaticFollowUps: automaticFollowUps,
                visibility: visibility, snoozeRequest: $snoozeRequest)
            TodayUnreadPanel(dashboard: dashboard, query: query)
        }
        // The sections below make room for "I owe" instead of jumping.
        .ternAnimation(value: owed.isEmpty)
    }
}

/// The follow-up card. Its header reads the loading and checking flags. The
/// rows are a child view, so those flags never redraw them.
private struct TodayFollowUpsSection: View {
    @Bindable var model: TodayModel
    let automaticFollowUps: AutomaticFollowUpCoordinator?
    let visibility: TodayRowVisibility
    @Binding var snoozeRequest: TodaySnoozeRequest?

    var body: some View {
        let isChecking = automaticFollowUps?.isChecking == true
        TodayDashboardSection(title: "Follow-up emails", symbol: "clock.arrow.circlepath",
                              count: model.hasLoadedEntries ? model.presentation.followUpCount : nil,
                              countLabel: "follow-ups shown",
                              updatingLabel: isChecking ? "Checking synced conversations…" : "Updating follow-ups…",
                              isUpdating: isChecking || (model.isLoading && model.hasLoadedEntries)) {
            filter
            if let automaticFollowUps { automaticStatus(automaticFollowUps) }
            TodayFollowUpList(model: model, visibility: visibility, snoozeRequest: $snoozeRequest)
            Divider()
            TodayCoverageNote(summary: "From synced mail and your tracked conversations.",
                details: automaticFollowUps?.coverageMessage ?? "Automatic and manually tracked follow-ups. Mail that has not synced is not included.",
                label: "Follow-up coverage")
                .accessibilityIdentifier("today-coverage")
        }
        .accessibilityIdentifier("today-follow-ups")
    }

    private var filter: some View {
        Picker("Today", selection: $model.filter) {
            Text("Briefing").tag(TodayFilter.briefing)
            Text("Snoozed").tag(TodayFilter.snoozed)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Today filter")
        .accessibilityIdentifier("today-filter")
    }

    @ViewBuilder private func automaticStatus(_ coordinator: AutomaticFollowUpCoordinator) -> some View {
        // The section header shows the check in its fixed slot, so a check no longer moves the list.
        let errors = [coordinator.errorMessage, coordinator.draftErrorMessage].compactMap { $0 }
        if !errors.isEmpty {
            TodayInlineWarning(errors.joined(separator: "\n")) {
                Task {
                    if coordinator.stopped { await coordinator.start() }
                    else { await coordinator.preferencesChanged() }
                }
            }
            .disabled(coordinator.isChecking)
            .accessibilityIdentifier("today-automatic-follow-ups-error")
        }
    }
}

/// The follow-up rows with their loading and empty states. It draws the list
/// the model prepared and is redrawn when that list, the filter or the search changes.
private struct TodayFollowUpList: View {
    let model: TodayModel
    let visibility: TodayRowVisibility
    @Binding var snoozeRequest: TodaySnoozeRequest?

    var body: some View {
        let presentation = model.presentation, sections = presentation.sections
        // The loading flag is read only before the first load, so a later
        // refresh does not redraw a list that already has its rows.
        let isFirstLoad = !model.hasLoadedEntries && model.isLoading
        VStack(alignment: .leading, spacing: 0) {
            if isFirstLoad {
                TodayLoadingStatus("Loading tracked work…").ternDelayedLoading().ternTransition(.fade)
            } else if presentation.rows.isEmpty {
                TodayCompactState(title: emptyTitle, symbol: model.filter == .snoozed ? "moon.zzz" : "checklist",
                    message: emptyMessage)
                    .accessibilityIdentifier("today-empty")
                    .modifier(TodayVisibilityReport(visibility: visibility, id: nil))
                    .ternTransition(.fade)
            } else {
                // One lazy stack holds every section's heading and rows, so the
                // scroll view measures a single list of rows.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        heading(section)
                            .padding(.top, section.id == sections.first?.id ? 0 : Tokens.Space.s4)
                            .padding(.bottom, Tokens.Space.s2)
                        ForEach(section.rows) { row in
                            TodayPresentedRow(row: row, snooze: presentation.snooze, model: model,
                                visibility: visibility, snoozeRequest: $snoozeRequest)
                            if row.id != section.rows.last?.id { Divider() }
                        }
                    }
                    if sections.isEmpty {
                        TodayCompactState(title: "No other follow-ups to show", symbol: "tray",
                            message: "Your commitments are listed in I owe above.")
                    }
                }
                .accessibilityIdentifier("today-list")
                .ternTransition(.fade)
            }
        }
        .ternAnimation(value: TodayContentKey(states: [isFirstLoad, model.filter == .snoozed], ids: presentation.contentIDs))
    }

    private func heading(_ section: TodaySection) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            Text(section.title).font(.subheadline.weight(.semibold))
            Text(section.rows.count, format: .number).font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-section-\(section.id)")
    }

    private var emptyTitle: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching tracked work" }
        return model.filter == .snoozed ? "No snoozed follow-ups" : "No tracked work to show"
    }

    private var emptyMessage: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Try another search or switch the Today filter." }
        if model.filter == .snoozed { return "Snoozed follow-ups will appear here until they return to your briefing." }
        return "Automatic follow-ups depend on synced sent mail and your settings. You can also open an email and choose Track Follow-up."
    }
}

/// One tracked row with its actions. It reads its account name, reply check and
/// busy state itself, so the list hands it only the row and redraws without it
/// when the row is unchanged.
private struct TodayPresentedRow: View {
    let row: TodayRow
    let snooze: TodaySnoozeChoices
    let model: TodayModel
    let visibility: TodayRowVisibility
    @Binding var snoozeRequest: TodaySnoozeRequest?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let entry = row.entry, followUps = model.followUps
        TodayRowView(row: row, accountName: followUps.accountName(for: entry.record.accountID),
            checkState: followUps.replyCheckState(for: entry), snooze: snooze,
            isBusy: followUps.busyIDs.contains(entry.id),
            onEdit: { followUps.edit(entry) },
            onComplete: { Task { await followUps.setStatus(entry, status: .completed) } },
            onDismiss: { Task { await followUps.setStatus(entry, status: .dismissed) } },
            onReopen: { Task { await followUps.setStatus(entry, status: .open) } },
            onDefer: { until in Task { await followUps.deferAttention(entry, until: until) } },
            onChooseDate: { snoozeRequest = TodaySnoozeRequest(entry: entry) },
            onBringBack: { Task { await followUps.deferAttention(entry, until: nil) } },
            onOpenSource: { followUps.openSource(entry) },
            onDraft: {
                Task {
                    if let id = await followUps.draftFollowUp(entry) { openWindow(id: ComposeWindow.sceneID, value: id) }
                }
            })
            .modifier(TodayVisibilityReport(visibility: visibility, id: row.id))
    }
}
