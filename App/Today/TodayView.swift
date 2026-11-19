import MailStore
import SwiftUI

struct TodayView: View {
    let model: TodayModel
    let dashboard: TodayDashboardModel
    /// Today is the section in front and on screen. It is false while another
    /// section is in front and while the utility panel fills a narrow window.
    let isActive: Bool
    /// Today is the section in front, on screen or under the utility panel.
    /// Nil means the same as `isActive`.
    var isInFront: Bool? = nil
    var automaticFollowUps: AutomaticFollowUpCoordinator? = nil
    /// Today has nothing that takes the keyboard, so as it comes to front it
    /// takes the keyboard from the sections behind it.
    @State private var keyboard = SectionKeyboard()
    @State private var windowVisible = false
    /// Whether the calendar fits beside the work column. The page learns the
    /// window's width only through this, so a resize redraws it at the threshold alone.
    @State private var isWide = true
    @State private var snoozeRequest: TodaySnoozeRequest?
    @State private var calendarExpanded = false
    @State private var visibility = TodayRowVisibility()

    private var isPresented: Bool { isActive && windowVisible }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                TodayHeader(model: model, dashboard: dashboard, isPresented: isPresented)
                TodayFeedback(model: model)
                if isWide {
                    HStack(alignment: .top, spacing: Tokens.Today.columnGap) {
                        workColumn.frame(maxWidth: .infinity)
                        TodayCalendarPanel(dashboard: dashboard, query: query)
                            .frame(width: Tokens.Today.calendarWidth)
                    }
                } else {
                    compactCalendar
                    workColumn
                }
            }
            .frame(maxWidth: Tokens.Today.contentWidth, alignment: .leading)
            .padding(isWide ? Tokens.Today.pageInset : Tokens.Today.compactInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Tokens.Today.twoColumnMinWidth } action: { isWide = $0 }
        .background(Tokens.Surface.muted)
        .background(TodayAcknowledgement(model: model, visibility: visibility, isActive: isPresented))
        .background(TodayClock(model: model, isPresented: isPresented))
        .background(ReaderWindowVisibility { visible in
            windowVisible = visible
            if !visible { model.endVisit(); dashboard.stop() }
        })
        .sectionKeyboard(keyboard, isInFront: isInFront ?? isActive, isShown: isActive)
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

    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var workColumn: some View {
        TodayWorkColumn(model: model, dashboard: dashboard, automaticFollowUps: automaticFollowUps,
            visibility: visibility, query: query, snoozeRequest: $snoozeRequest)
    }

    private var compactCalendar: some View {
        DisclosureGroup(isExpanded: $calendarExpanded) {
            TodayCalendarPanel(dashboard: dashboard, query: query)
                .padding(.top, Tokens.Space.s3)
        } label: {
            HStack(spacing: Tokens.Space.s3) {
                Label("Calendar and events", systemImage: "calendar")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text(dashboard.selectedDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("today-calendar-disclosure")
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

/// The title, the date and the page's loading indicator. The clock and the
/// loading flags are read here, so they redraw this row and nothing below it.
private struct TodayHeader: View {
    let model: TodayModel
    let dashboard: TodayDashboardModel
    let isPresented: Bool
    /// The date a hidden page keeps, so it isn't redrawn every minute.
    @State private var hiddenAt = Date.now

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s4) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("Today").font(.largeTitle.weight(.semibold))
                Text((isPresented ? MinuteClock.shared.now : hiddenAt).formatted(date: .complete, time: .omitted))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ProgressView().controlSize(.small).accessibilityLabel("Updating dashboard")
                .ternDelayedLoading(model.isLoading || dashboard.calendarLoading || dashboard.unreadLoading || dashboard.tasks.isLoading)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh(); await dashboard.refresh() }
            }
            .controlSize(.regular).help("Refresh Today")
            .accessibilityIdentifier("today-refresh")
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { hiddenAt = MinuteClock.shared.now }
        }
    }
}

/// Errors from the visit history and from the follow-ups, each with a retry.
private struct TodayFeedback: View {
    let model: TodayModel

    var body: some View {
        if let error = model.historyError {
            message(error, identifier: "today-history-error")
        }
        if let error = model.followUps.errorMessage {
            message(error, identifier: "today-error")
        }
    }

    private func message(_ text: String, identifier: String) -> some View {
        TodayInlineWarning(text) {
            Task { await model.refresh() }
        }
        .disabled(model.isLoading)
        .accessibilityIdentifier(identifier)
    }
}

/// Rebuilds the list when the page comes on screen and at the start of each
/// minute while it stays there, so due and snoozed rows move when their time
/// comes. A hidden page reads no clock.
private struct TodayClock: View {
    let model: TodayModel
    let isPresented: Bool

    var body: some View {
        Color.clear.accessibilityHidden(true)
            .onChange(of: isPresented ? MinuteClock.shared.now : nil) { _, minute in
                if minute != nil { model.refreshPresentation() }
            }
    }
}

/// What the follow-up list has on screen. Rows write here without invalidating
/// any view; only the acknowledgement task reads `revision`.
@MainActor @Observable
final class TodayRowVisibility {
    private(set) var revision = 0
    @ObservationIgnored private var rows: [String: Int] = [:]
    @ObservationIgnored private var emptyStates = 0

    var showsEmptyState: Bool { emptyStates > 0 }
    func contains(_ id: String) -> Bool { rows[id] != nil }

    /// A nil ID is the empty state. A row can move to another section before
    /// its old view disappears, so views are counted per ID.
    func report(_ id: String?, visible: Bool) {
        if let id {
            let count = rows[id, default: 0] + (visible ? 1 : -1)
            rows[id] = count > 0 ? count : nil
        } else {
            emptyStates = max(0, emptyStates + (visible ? 1 : -1))
        }
        revision += 1
    }
}

struct TodayVisibilityReport: ViewModifier {
    let visibility: TodayRowVisibility
    let id: String?
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            // Lazy stacks can prepare rows outside the viewport. Count a row
            // only once a meaningful part of it is actually on screen.
            .onScrollVisibilityChange(threshold: 0.1) { report($0) }
            .onDisappear { report(false) }
    }

    private func report(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        visibility.report(id, visible: visible)
    }
}

/// One task for the whole list. It passes every row on screen to the model in
/// one call, so a visit or a change costs one save, not one per row.
private struct TodayAcknowledgement: View {
    let model: TodayModel
    let visibility: TodayRowVisibility
    let isActive: Bool

    var body: some View {
        let presentation = model.presentation
        Color.clear.accessibilityHidden(true)
            .task(id: Key(snapshots: presentation.snapshots, visitID: model.activeVisitID, historyReady: model.historyReady,
                          isActive: isActive, hasLoadedEntries: model.hasLoadedEntries,
                          revision: model.presentationRevision, visibility: visibility.revision)) {
                guard isActive, model.historyReady, model.hasLoadedEntries, let visitID = model.activeVisitID else { return }
                // Rows that appear in this update report themselves first.
                await Task.yield()
                guard !Task.isCancelled else { return }
                let rows = presentation.rows
                let visible = rows.filter { visibility.contains($0.id) }
                guard !visible.isEmpty || (rows.isEmpty && visibility.showsEmptyState) else { return }
                model.acknowledgeVisible(visible, visitID: visitID)
            }
    }

    private struct Key: Equatable {
        let snapshots: [TodayCommitmentSnapshot]
        let visitID: UUID?
        let historyReady: Bool
        let isActive: Bool
        let hasLoadedEntries: Bool
        let revision: Int
        let visibility: Int
    }
}
