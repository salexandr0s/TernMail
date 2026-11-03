import MailStore
import SwiftUI

struct FollowUpsView: View {
    @Bindable var model: FollowUpsModel
    @Environment(\.openWindow) private var openWindow
    @State private var direction: DirectionFilter = .all
    @State private var showsHistory = false

    private enum DirectionFilter: String, CaseIterable, Identifiable {
        case all = "All", waitingFor = "Waiting for", owedByMe = "I owe"
        var id: String { rawValue }
    }

    private var filteredEntries: [CommitmentEntry] {
        model.visibleEntries.filter { entry in
            let matchesDirection = direction == .all
                || (direction == .waitingFor && entry.record.direction == .waitingFor)
                || (direction == .owedByMe && entry.record.direction == .owedByMe)
            return matchesDirection && ((entry.record.status != .open) == showsHistory)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            feedback
            content(now: MinuteClock.shared.now)
            footer
        }
        .background(Tokens.Surface.primary)
        .accessibilityIdentifier("follow-ups-view")
        .onChange(of: model.selectedEntryID, initial: true) { _, id in
            guard !filteredEntries.contains(where: { $0.id == id }),
                  let entry = model.visibleEntries.first(where: { $0.id == id }) else { return }
            direction = .all
            showsHistory = entry.record.status != .open
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s4) { directionPicker; Spacer(minLength: 0); historyPicker }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) { directionPicker; historyPicker }
        }
        .padding(Tokens.Space.s4)
        .background(Tokens.Surface.muted)
    }

    private var directionPicker: some View {
        Picker("Commitments", selection: $direction) {
            ForEach(DirectionFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Commitment direction")
        .accessibilityIdentifier("follow-up-direction-filter")
    }

    private var historyPicker: some View {
        Picker("Status", selection: $showsHistory) {
            Text("Open").tag(false)
            Text("History").tag(true)
        }
        .labelsHidden().pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Follow-up status")
        .accessibilityIdentifier("follow-up-status-filter")
    }

    @ViewBuilder private var feedback: some View {
        if let message = model.errorMessage {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Tokens.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Retry") { Task { await model.refresh() } }.disabled(model.isLoading)
            }
            .padding(Tokens.Space.s4)
            .accessibilityIdentifier("follow-ups-error")
        }
        if let notice = model.notice {
            Text(notice).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Space.s4).padding(.vertical, Tokens.Space.s2)
                .accessibilityIdentifier("follow-ups-notice")
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if model.isLoading && model.entries.isEmpty {
            ProgressView("Loading follow-ups…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
            TernEmptyState(title: emptyTitle, systemImage: showsHistory ? "checkmark.circle" : "clock.arrow.circlepath",
                message: emptyMessage)
        } else {
            ScrollViewReader { proxy in
                List(selection: $model.selectedEntryID) {
                    ForEach(filteredEntries) { entry in
                        FollowUpRow(entry: entry, accountName: model.accountName(for: entry.record.accountID),
                            checkState: model.replyCheckStates[entry.id], now: now, isBusy: model.busyIDs.contains(entry.id),
                            onEdit: { model.edit(entry) },
                            onComplete: { Task { await model.setStatus(entry, status: .completed) } },
                            onDismiss: { Task { await model.setStatus(entry, status: .dismissed) } },
                            onReopen: { Task { await model.setStatus(entry, status: .open) } },
                            onSnooze: { date in Task { await model.snooze(entry, until: date) } },
                            onOpenSource: { model.openSource(entry) },
                            onDraft: { draft(entry) })
                            .tag(entry.id)
                            .id(entry.id)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("follow-ups-list")
                .onChange(of: model.selectedEntryID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Divider()
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Reminders are checked while Tern is running and when it resumes.")
                    notificationStatus
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if case .notRequested = model.notificationPermission {
                    Button("Allow Notifications") { Task { await model.requestNotificationPermission() } }
                        .controlSize(.small)
                        .accessibilityIdentifier("follow-ups-allow-notifications")
                }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.bottom, Tokens.Space.s3)
        }
    }

    @ViewBuilder private var notificationStatus: some View {
        switch model.notificationPermission {
        case .allowed: EmptyView()
        case .denied: Text("Notifications are off. Due items stay here; you can allow Tern notifications in System Settings.")
        case .notRequested: Text("Due items stay here even without notifications.")
        }
    }

    private var emptyTitle: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching follow-ups" }
        return showsHistory ? "No completed or dismissed follow-ups" : "No open follow-ups"
    }

    private var emptyMessage: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Try another search or change the filters." }
        if showsHistory { return "Completed and dismissed commitments will appear here. You can reopen them later." }
        return "Open an email and choose Track Follow-up from its actions menu, or track a task from its summary."
    }

    private func draft(_ entry: CommitmentEntry) {
        Task {
            if let id = await model.draftFollowUp(entry) { openWindow(id: ComposeWindow.sceneID, value: id) }
        }
    }
}
