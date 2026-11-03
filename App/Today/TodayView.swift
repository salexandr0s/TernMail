import MailStore
import SwiftUI

struct TodayView: View {
    @Bindable var model: TodayModel
    @Bindable var dashboard: TodayDashboardModel
    let isActive: Bool
    var automaticFollowUps: AutomaticFollowUpCoordinator? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var windowVisible = false
    @State private var snoozeRequest: TodaySnoozeRequest?

    private var isPresented: Bool { isActive && windowVisible }

    var body: some View {
        let now = MinuteClock.shared.now
        let projection = model.projection(now: now)
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.s5) {
                    header
                    feedback
                    if geometry.size.width >= Tokens.Layout.listMinWidth + Tokens.Calendar.sidebarWidth + Tokens.Space.s16 * 2 {
                        HStack(alignment: .top, spacing: Tokens.Space.s5) {
                            todoColumn(projection, now: now).frame(maxWidth: .infinity)
                            TodayCalendarPanel(dashboard: dashboard, query: query)
                                .frame(width: Tokens.Calendar.sidebarWidth + Tokens.Space.s8)
                        }
                    } else {
                        todoColumn(projection, now: now)
                        TodayCalendarPanel(dashboard: dashboard, query: query)
                    }
                    TodayUnreadPanel(dashboard: dashboard, query: query)
                    followUps(projection, now: now)
                }
                .padding(Tokens.Space.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Tokens.Surface.muted)
        .background(ReaderWindowVisibility { visible in
            windowVisible = visible
            if !visible { model.endVisit(); dashboard.stop() }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-view")
        .task(id: VisitKey(context: model.visitContext, isPresented: isPresented)) {
            if isPresented { await model.beginVisit() }
        }
        .task(id: DashboardKey(context: dashboard.context, isPresented: isPresented)) {
            if isPresented { await dashboard.refresh() }
        }
        .task(id: CalendarKey(request: dashboard.calendarRequest, isPresented: isPresented)) {
            if isPresented { await dashboard.refreshCalendar() }
        }
        .onChange(of: isActive) { _, active in if !active { model.endVisit(); dashboard.stop() } }
        .onDisappear { model.endVisit(); dashboard.stop() }
        .sheet(item: $snoozeRequest) { request in
            TodaySnoozeEditor(request: request, followUps: model.followUps)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Today").font(.largeTitle.weight(.semibold))
                Text(MinuteClock.shared.now.formatted(date: .complete, time: .omitted))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isLoading || dashboard.calendarLoading || dashboard.unreadLoading || dashboard.tasks.isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("Updating dashboard")
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh(); await dashboard.refresh() }
            }
            .labelStyle(.iconOnly).help("Refresh Today")
            .accessibilityIdentifier("today-refresh")
        }
    }

    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func isOwed(_ row: TodayRow) -> Bool {
        model.filter == .briefing && row.entry.record.status == .open && row.entry.record.direction == .owedByMe
    }

    private func todoColumn(_ projection: TodayProjection, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            TodayTasksPanel(dashboard: dashboard, query: query)
            let owed = projection.rows.filter(isOwed)
            if !owed.isEmpty {
                TodayDashboardSection(title: "I owe", symbol: "person.crop.circle") {
                    Text("Responses and actions you track in Tern.").font(.caption).foregroundStyle(.secondary)
                    LazyVStack(spacing: Tokens.Space.s3) {
                        ForEach(owed) { row in presentedRow(row, now: now) }
                    }
                }
                .accessibilityIdentifier("today-owed")
            }
        }
    }

    private func followUps(_ projection: TodayProjection, now: Date) -> some View {
        TodayDashboardSection(title: "Follow-up emails", symbol: "clock.arrow.circlepath") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s3) { filter; Spacer(minLength: 0); coverage }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) { filter; coverage }
            }
            if let automaticFollowUps { automaticStatus(automaticFollowUps) }
            content(projection, now: now)
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

    private var coverage: some View {
        Text("Automatic and manually tracked follow-ups.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("today-coverage")
    }

    private func automaticStatus(_ coordinator: AutomaticFollowUpCoordinator) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(coordinator.coverageMessage).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if coordinator.isChecking {
                ProgressView("Checking synced conversations…").controlSize(.small)
            }
            let errors = [coordinator.errorMessage, coordinator.draftErrorMessage].compactMap { $0 }
            if !errors.isEmpty {
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    Label(errors.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(Tokens.Status.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry") {
                        Task {
                            if coordinator.stopped { await coordinator.start() }
                            else { await coordinator.preferencesChanged() }
                        }
                    }
                    .disabled(coordinator.isChecking)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today-automatic-follow-ups-error")
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        if let error = model.historyError {
            message(error, systemImage: "clock.badge.exclamationmark", identifier: "today-history-error")
        }
        if let error = model.followUps.errorMessage {
            message(error, systemImage: "exclamationmark.circle", identifier: "today-error")
        }
    }

    private func message(_ text: String, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Label(text, systemImage: systemImage)
                .font(.callout).foregroundStyle(Tokens.Status.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { Task { await model.refresh() } }.disabled(model.isLoading)
        }
        .padding(Tokens.Space.s4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private func content(_ projection: TodayProjection, now: Date) -> some View {
        if model.isLoading && !model.hasLoadedEntries {
            ProgressView("Loading tracked work…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projection.rowCount == 0 {
            TernEmptyState(title: emptyTitle, systemImage: model.filter == .snoozed ? "moon.zzz" : "sun.max",
                message: emptyMessage)
                .accessibilityIdentifier("today-empty")
                .modifier(TodayPresentationAcknowledgement(model: model, rows: [], isActive: isPresented))
        } else {
            LazyVStack(alignment: .leading, spacing: Tokens.Space.s4) {
                ForEach(projection.sections) { section in
                    let rows = section.rows.filter { !isOwed($0) }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("today-section-\(section.id)")
                            LazyVStack(spacing: Tokens.Space.s3) {
                                ForEach(rows) { row in presentedRow(row, now: now) }
                            }
                        }
                    }
                }
                if projection.rows.allSatisfy(isOwed) {
                    Text("Your tracked work appears in I owe above.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("today-list")
        }
    }

    private func presentedRow(_ row: TodayRow, now: Date) -> some View {
        rowView(row, now: now)
            .modifier(TodayPresentationAcknowledgement(model: model, rows: [row], isActive: isPresented))
    }

    private func rowView(_ row: TodayRow, now: Date) -> some View {
        let entry = row.entry
        return TodayRowView(row: row, accountName: model.followUps.accountName(for: entry.record.accountID),
            checkState: model.followUps.replyCheckState(for: entry), now: now,
            isBusy: model.followUps.busyIDs.contains(entry.id),
            onEdit: { model.followUps.edit(entry) },
            onComplete: { Task { await model.followUps.setStatus(entry, status: .completed) } },
            onDismiss: { Task { await model.followUps.setStatus(entry, status: .dismissed) } },
            onReopen: { Task { await model.followUps.setStatus(entry, status: .open) } },
            onDefer: { until in Task { await model.followUps.deferAttention(entry, until: until) } },
            onChooseDate: { snoozeRequest = TodaySnoozeRequest(entry: entry) },
            onBringBack: { Task { await model.followUps.deferAttention(entry, until: nil) } },
            onOpenSource: { model.followUps.openSource(entry) },
            onDraft: {
                Task {
                    if let id = await model.followUps.draftFollowUp(entry) { openWindow(id: ComposeWindow.sceneID, value: id) }
                }
            })
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

    private struct VisitKey: Equatable {
        let context: TodayVisitContext
        let isPresented: Bool
    }

    private struct DashboardKey: Equatable {
        let context: TodayDashboardContext
        let isPresented: Bool
    }

    private struct CalendarKey: Equatable {
        let request: TodayDashboardCalendarRequest
        let isPresented: Bool
    }

}

private struct TodayPresentationAcknowledgement: ViewModifier {
    let model: TodayModel
    let rows: [TodayRow]
    let isActive: Bool
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            // Lazy stacks can prepare rows outside the viewport. Wait until a
            // meaningful part of this row is actually visible before saving it.
            .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
            .onDisappear { isVisible = false }
            .task(id: Key(snapshots: rows.map(\.snapshot), visitID: model.activeVisitID,
                          historyReady: model.historyReady, isPresented: isActive && isVisible,
                          hasLoadedEntries: model.hasLoadedEntries, revision: model.presentationRevision)) {
                guard isActive, isVisible, model.historyReady, model.hasLoadedEntries,
                      let visitID = model.activeVisitID else { return }
                let presented = rows
                await Task.yield()
                guard !Task.isCancelled else { return }
                await model.acknowledgePresented(presented, visitID: visitID)
            }
    }

    private struct Key: Equatable {
        let snapshots: [TodayCommitmentSnapshot]
        let visitID: UUID?
        let historyReady: Bool
        let isPresented: Bool
        let hasLoadedEntries: Bool
        let revision: Int
    }
}
