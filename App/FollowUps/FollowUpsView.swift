import MailStore
import SwiftUI

struct FollowUpsView: View {
    @Bindable var model: FollowUpsModel
    /// The page is in front and on screen. It is false while another section is in front and while the
    /// utility panel fills a narrow window. The page stays mounted, and its rows stop following the clock.
    var isActive = true
    /// The page is in front, on screen or under the utility panel. Nil means the same as `isActive`.
    var isInFront: Bool? = nil
    /// Moves the keyboard to the list as the page comes to front.
    @State private var keyboard = SectionKeyboard()
    @State private var direction: DirectionFilter = .all
    @State private var showsHistory = false

    fileprivate enum DirectionFilter: String, CaseIterable, Identifiable {
        case all = "All", waitingFor = "Waiting for", owedByMe = "I owe"
        var id: String { rawValue }

        /// Whether an entry belongs under this direction on the Open or History tab.
        func includes(_ entry: CommitmentEntry, history: Bool) -> Bool {
            let matchesDirection = switch self {
            case .all: true
            case .waitingFor: entry.record.direction == .waitingFor
            case .owedByMe: entry.record.direction == .owedByMe
            }
            return matchesDirection && (entry.record.status != .open) == history
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            feedback
            FollowUpsContent(model: model, direction: direction, showsHistory: showsHistory, isActive: isActive,
                isInFront: isInFront ?? isActive, keyboard: keyboard)
            footer
        }
        // A banner that appears or leaves moves the list; animate that move.
        .ternAnimation(value: [model.errorMessage, model.notice])
        .background(Tokens.Surface.primary)
        .sectionKeyboard(keyboard, isInFront: isInFront ?? isActive, isShown: isActive)
        .accessibilityIdentifier("follow-ups-view")
        .onChange(of: model.selectedEntryID, initial: true) { _, id in
            guard let entry = model.visibleEntries.first(where: { $0.id == id }),
                  !direction.includes(entry, history: showsHistory) else { return }
            direction = .all
            showsHistory = entry.record.status != .open
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s4) { directionPicker; Spacer(minLength: 0); historyPicker }
                .readableColumn()
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
            .readableColumn()
            .padding(Tokens.Space.s4)
            .accessibilityIdentifier("follow-ups-error")
            .ternTransition(.disclosure)
        }
        if let notice = model.notice {
            Text(notice).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableColumn()
                .padding(.horizontal, Tokens.Space.s4).padding(.vertical, Tokens.Space.s2)
                .accessibilityIdentifier("follow-ups-notice")
                .ternTransition(.disclosure)
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
            .readableColumn()
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
}

/// The list with its loading and empty states. It is a separate view so the
/// minute tick, reply checks and busy rows update the rows without the filter
/// bar, banners and footer, and so changes there leave the rows alone.
private struct FollowUpsContent: View {
    @Bindable var model: FollowUpsModel
    let direction: FollowUpsView.DirectionFilter
    let showsHistory: Bool
    let isActive: Bool
    /// The page is in front, on screen or under the utility panel.
    let isInFront: Bool
    let keyboard: SectionKeyboard
    /// The time a hidden page's rows keep, so they aren't rebuilt every minute.
    @State private var hiddenAt = Date.now
    @FocusState private var listFocused: Bool
    @Environment(\.openWindow) private var openWindow

    private enum Phase { case list, loading, empty }

    var body: some View {
        // One filter pass per update. The branches below share its result.
        let entries = model.visibleEntries.filter { direction.includes($0, history: showsHistory) }
        // The loading flag is read only while nothing is saved, so a refresh
        // does not re-evaluate a page that already has entries.
        let phase: Phase = !entries.isEmpty ? .list : model.entries.isEmpty && model.isLoading ? .loading : .empty
        // The three states share one place and cross-fade.
        ZStack {
            switch phase {
            case .list:
                list(entries, now: isActive ? MinuteClock.shared.now : hiddenAt)
                    .ternTransition(.fade)
            case .loading:
                ProgressView("Loading follow-ups…")
                    .ternDelayedLoading()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ternTransition(.fade)
            case .empty:
                TernEmptyState(title: emptyTitle, systemImage: showsHistory ? "checkmark.circle" : "clock.arrow.circlepath",
                    message: emptyMessage)
                    .ternTransition(.fade)
            }
        }
        .ternAnimation(value: phase)
        .onChange(of: isActive) { _, active in
            if !active { hiddenAt = MinuteClock.shared.now }
        }
        // The list gives up the keyboard as the page goes behind. When the
        // utility panel covers the page instead, its Back button takes it.
        .onChange(of: isInFront) { _, inFront in
            if !inFront { listFocused = false }
        }
    }

    private func list(_ entries: [CommitmentEntry], now: Date) -> some View {
        ScrollViewReader { proxy in
            List(selection: $model.selectedEntryID) {
                ForEach(entries) { entry in
                    FollowUpRow(entry: entry, accountName: model.accountName(for: entry.record.accountID),
                        checkState: model.replyCheckStates[entry.id], now: now, isBusy: model.busyIDs.contains(entry.id),
                        onEdit: { model.edit(entry) },
                        onComplete: { Task { await model.setStatus(entry, status: .completed) } },
                        onDismiss: { Task { await model.setStatus(entry, status: .dismissed) } },
                        onReopen: { Task { await model.setStatus(entry, status: .open) } },
                        onSnooze: { date in Task { await model.snooze(entry, until: date) } },
                        onOpenSource: { model.openSource(entry) },
                        onDraft: { draft(entry) },
                        onBringBack: { Task { await model.deferAttention(entry, until: nil) } })
                        .readableColumn()
                        .tag(entry.id)
                        .id(entry.id)
                }
            }
            .listStyle(.inset)
            // Rows that arrive or leave fade, and the rest move to their place.
            .ternAnimation(value: entries.map(\.id))
            .accessibilityIdentifier("follow-ups-list")
            .focused($listFocused)
            .takesSectionKeyboard(keyboard) { listFocused = true }
            .onChange(of: model.selectedEntryID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
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
        ComposeWindow.open(with: openWindow) { await model.draftFollowUp(entry) }
    }
}

private extension View {
    /// Keeps content in a column of readable width, centered when the page is wider.
    func readableColumn() -> some View {
        frame(maxWidth: Tokens.Layout.readableWidth, alignment: .leading).frame(maxWidth: .infinity)
    }
}
