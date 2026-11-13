import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var followUpsWorkspaceHasFocus: Bool?
    @Entry var todayWorkspaceHasFocus: Bool?
}

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case mail, calendar, today, followUps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .followUps: "Waiting for"
        case .today: "Today"
        }
    }
}

/// Keeping destination views mounted preserves native selection and scroll positions.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var calendarPanel: WorkspacePanel?
    @State private var calendarSidebar = CalendarSidebarState()
    @State private var tasksAllowClosing = true
    @FocusState private var compactBackFocused: Bool
    /// Shared with the mail assistant, so the panel keeps one width across launches.
    @AppStorage(AssistantSidebarLayout.widthKey) private var preferredAssistantWidth = Double(Tokens.Assistant.sidebarWidth)
    /// The panel's width while its divider is dragged; saved when the drag ends.
    @State private var draggedAssistantWidth: CGFloat?
    let mailbox: MailboxModel

    var body: some View {
        GeometryReader { geometry in
            let layout = CalendarUtilityLayout(availableWidth: geometry.size.width,
                preferredWidth: draggedAssistantWidth ?? CGFloat(preferredAssistantWidth), isPresented: calendarPanel != nil)
            ZStack {
                MainView(mailbox: mailbox, isActive: app.destination == .mail, windowWidth: geometry.size.width,
                    calendarPanel: calendarPanel,
                    onCalendarPanelToggle: toggleCalendarPanel, calendarSidebarState: calendarSidebar,
                    isCalendarUtilityCompact: layout.isCompact)
                    .opacity(app.destination == .mail ? 1 : 0)
                    .allowsHitTesting(app.destination == .mail)
                    .accessibilityHidden(app.destination != .mail)
                    .zIndex(app.destination == .mail ? 1 : 0)
                    .background {
                        MailWorkspacePerformance(mailbox: mailbox, isActive: app.destination == .mail)
                    }
                ZStack(alignment: .topLeading) {
                    ZStack {
                        CalendarView(model: app.calendar, isActive: app.destination == .calendar && !layout.isCompact,
                            sidebarState: calendarSidebar, onDeactivateFocus: {
                                if layout.isCompact { compactBackFocused = true }
                            })
                            .opacity(app.destination == .calendar ? 1 : 0)
                            .allowsHitTesting(app.destination == .calendar)
                            .accessibilityHidden(app.destination != .calendar)
                            .focusedValue(\.calendarWorkspaceHasFocus, app.destination == .calendar)
                        FollowUpsView(model: app.followUps, isActive: app.destination == .followUps)
                            .opacity(app.destination == .followUps ? 1 : 0)
                            .allowsHitTesting(app.destination == .followUps)
                            .accessibilityHidden(app.destination != .followUps)
                            .focusedValue(\.followUpsWorkspaceHasFocus, app.destination == .followUps)
                            .background {
                                FollowUpsWorkspacePerformance(model: app.followUps,
                                    isActive: app.destination == .followUps && !layout.isCompact)
                            }
                        TodayView(model: app.today, dashboard: app.todayDashboard,
                            isActive: app.destination == .today && !layout.isCompact,
                            automaticFollowUps: app.automaticFollowUps)
                            .opacity(app.destination == .today ? 1 : 0)
                            .allowsHitTesting(app.destination == .today)
                            .accessibilityHidden(app.destination != .today)
                            .focusedValue(\.todayWorkspaceHasFocus, app.destination == .today)
                            .background {
                                TodayWorkspacePerformance(model: app.today,
                                    isActive: app.destination == .today && !layout.isCompact)
                            }
                    }
                    .frame(width: layout.calendarWidth, height: geometry.size.height, alignment: .leading)
                    .clipped()
                    .opacity(layout.isCompact ? 0 : 1)
                    .allowsHitTesting(!layout.isCompact)
                    .accessibilityHidden(layout.isCompact)
                    if let calendarPanel {
                        CalendarUtilityPanel(layout: layout, height: geometry.size.height,
                            title: calendarPanel == .tasks ? "Tasks" : "Assistant",
                            canClose: calendarPanel != .tasks || tasksAllowClosing,
                            backFocused: $compactBackFocused, onBack: closeCalendarPanel, onResize: resizeAssistant,
                            onResizeEnd: saveAssistantWidth) {
                            ZStack {
                                if calendarPanel == .tasks {
                                    GoogleTasksSidebar(model: app.tasks, onClose: closeCalendarPanel,
                                        isActive: app.destination != .mail,
                                        onCloseAvailabilityChange: { tasksAllowClosing = $0 })
                                        .ternTransition(.fade)
                                } else {
                                    AssistantView(model: app.assistant, onOpenSource: app.openAssistantSource,
                                        onExpand: { openAssistant(fullScreen: true) },
                                        onDetach: { openAssistant(fullScreen: false) }, onClose: closeCalendarPanel)
                                        .ternTransition(.fade)
                                }
                            }
                            .ternAnimation(value: calendarPanel, duration: Tokens.Motion.fast)
                        }
                        .ternTransition(.panel(edge: .trailing))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .ternAnimation(value: calendarPanel != nil, duration: Tokens.Motion.slow)
                .clipped()
                .opacity(app.destination != .mail ? 1 : 0)
                .allowsHitTesting(app.destination != .mail)
                .accessibilityHidden(app.destination == .mail)
                .zIndex(app.destination != .mail ? 1 : 0)
                .background {
                    CalendarWorkspacePerformance(model: app.calendar, isActive: app.destination == .calendar)
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Tokens.Surface.border)
                    .frame(height: Tokens.Border.hairline)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .toolbar(removing: .sidebarToggle)
            .followUpEditor(model: app.followUps)
            .background {
                CalendarWorkspaceFocusTransfer(isCompact: layout.isCompact,
                    isCalendarActive: app.destination == .calendar,
                    isFollowUpsActive: app.destination == .followUps,
                    isTodayActive: app.destination == .today) {
                    compactBackFocused = true
                }
            }
            .background {
                CalendarStart(calendar: app.calendar, mailbox: mailbox, destination: app.destination)
            }
            .onChange(of: app.tasksSidebarRequest, initial: true) { _, request in
                if app.destination != .mail, request != nil {
                    if calendarPanel != .tasks { toggleCalendarPanel(.tasks) }
                    app.didShowTasks()
                }
            }
            .onChange(of: app.destination, initial: true) { _, destination in
                app.calendar.isVisible = destination == .calendar
                // The Tasks panel sits beside Calendar, so its first read starts here.
                if destination == .calendar { app.tasks.preload() }
            }
            .onChange(of: mailbox.accounts.map(\.account.id)) { _, _ in
                Task { await app.calendar.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await app.calendar.refresh() }
            }
        }
    }

    private func toggleCalendarPanel(_ panel: WorkspacePanel) {
        guard calendarPanel != .tasks || tasksAllowClosing else { return }
        calendarPanel = calendarPanel == panel ? nil : panel
    }

    private func closeCalendarPanel() {
        guard calendarPanel != .tasks || tasksAllowClosing else { return }
        calendarPanel = nil
    }

    private func resizeAssistant(_ width: CGFloat) {
        draggedAssistantWidth = AssistantSidebarLayout.clampedWidth(width)
    }

    private func saveAssistantWidth() {
        guard let width = draggedAssistantWidth else { return }
        preferredAssistantWidth = Double(width)
        draggedAssistantWidth = nil
    }

    private func openAssistant(fullScreen: Bool) {
        calendarPanel = nil
        AssistantWindow.open(using: openWindow, fullScreen: fullScreen)
    }
}

/// Starts Calendar once per workspace. Calendar and Today need it at once.
/// Behind Mail it waits for the first page of the list, so opening its store
/// and syncing do not compete with that page, and for at most
/// `Tokens.Calendar.startDelay`. Event reminders and meeting preparation
/// therefore work for someone who never opens Calendar.
///
/// It is a view of its own so the list's readiness is observed here and a
/// mailbox switch does not re-evaluate the workspace.
private struct CalendarStart: View {
    let calendar: CalendarModel
    let mailbox: MailboxModel
    let destination: WorkspaceDestination
    /// Set once and never cleared: a start that is under way must not be
    /// cancelled, because a cancelled start stops Calendar.
    @State private var isDue = false

    private var isNeededNow: Bool {
        destination == .calendar || destination == .today || mailbox.isListPresentationReady
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: isNeededNow, initial: true) { _, needed in
                if needed { isDue = true }
            }
            .task(id: isDue) {
                guard !isDue else { await calendar.start(); return }
                do { try await Task.sleep(for: Tokens.Calendar.startDelay) } catch { return }
                isDue = true
            }
    }
}

private struct CalendarWorkspaceFocusTransfer: View {
    let isCompact: Bool
    let isCalendarActive: Bool
    let isFollowUpsActive: Bool
    let isTodayActive: Bool
    let onNeedsBackFocus: () -> Void
    @FocusedValue(\.calendarWorkspaceHasFocus) private var calendarHasFocus
    @FocusedValue(\.followUpsWorkspaceHasFocus) private var followUpsHasFocus
    @FocusedValue(\.todayWorkspaceHasFocus) private var todayHasFocus

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: isCompact) { _, compact in
                if compact, (isCalendarActive && calendarHasFocus == true)
                    || (isFollowUpsActive && followUpsHasFocus == true)
                    || (isTodayActive && todayHasFocus == true) {
                    onNeedsBackFocus()
                }
            }
    }
}

/// Keep diagnostics' observation dependencies outside the expensive workspace
/// body. A new data revision should not re-evaluate both destination trees.
private struct MailWorkspacePerformance: View {
    let mailbox: MailboxModel
    let isActive: Bool

    private var ready: Bool {
        isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID && mailbox.isListPresentationReady
    }

    var body: some View {
        VisibleContentProbe(kinds: [.workspace, .mailbox],
            isActive: ready, revision: mailbox.listPresentationRevision)
        .onChange(of: ready, initial: true) { _, value in
            if value { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained) }
        }
        .onChange(of: mailbox.listPresentationRevision) { _, _ in
            if ready { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .local) }
        }
    }
}

private struct CalendarWorkspacePerformance: View {
    let model: CalendarModel
    let isActive: Bool

    private var ready: Bool { isActive && model.presentation != nil }

    var body: some View {
        VisibleContentProbe(kind: .workspace, isActive: ready, revision: model.presentationRevision)
            .onChange(of: ready, initial: true) { _, value in
                if value { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained) }
            }
            .onChange(of: model.presentationRevision) { _, _ in
                if ready { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .local) }
            }
    }
}

private struct FollowUpsWorkspacePerformance: View {
    let model: FollowUpsModel
    let isActive: Bool

    private var ready: Bool { isActive && model.hasLoadedEntries }

    var body: some View {
        VisibleContentProbe(kind: .workspace, isActive: ready, revision: model.presentationRevision)
            .onChange(of: ready, initial: true) { _, value in
                if value { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained) }
            }
            .onChange(of: model.presentationRevision) { _, _ in
                if ready { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .local) }
            }
    }
}

private struct TodayWorkspacePerformance: View {
    let model: TodayModel
    let isActive: Bool

    private var ready: Bool { isActive && model.hasLoadedEntries }

    var body: some View {
        VisibleContentProbe(kind: .workspace, isActive: ready, revision: model.presentationRevision)
            .onChange(of: ready, initial: true) { _, value in
                if value { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .retained) }
            }
            .onChange(of: model.presentationRevision) { _, _ in
                if ready { NavigationPerformance.shared.contentReady(.workspace, cacheTier: .local) }
            }
    }
}
