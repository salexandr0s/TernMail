import AppKit
import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case mail, calendar
    var id: String { rawValue }
    var title: String { self == .mail ? "Mail" : "Calendar" }
}

/// Keeping both views mounted preserves native selection and scroll positions.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var calendarPanel: WorkspacePanel?
    @State private var calendarSidebar = CalendarSidebarState()
    @State private var tasksAllowClosing = true
    @FocusState private var compactBackFocused: Bool
    @FocusedValue(\.calendarWorkspaceHasFocus) private var calendarHasFocus
    /// Shared with the mail assistant, so the panel keeps one width across launches.
    @AppStorage(AssistantSidebarLayout.widthKey) private var preferredAssistantWidth = Double(Tokens.Assistant.sidebarWidth)
    let mailbox: MailboxModel

    var body: some View {
        GeometryReader { geometry in
            let layout = CalendarUtilityLayout(availableWidth: geometry.size.width,
                preferredWidth: CGFloat(preferredAssistantWidth), isPresented: calendarPanel != nil)
            ZStack {
                MainView(mailbox: mailbox, isActive: app.destination == .mail,
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
                    CalendarView(model: app.calendar, isActive: app.destination == .calendar && !layout.isCompact,
                        sidebarState: calendarSidebar, onDeactivateFocus: {
                            if layout.isCompact { compactBackFocused = true }
                        })
                        .frame(width: layout.calendarWidth, height: geometry.size.height, alignment: .leading)
                        .clipped()
                        .opacity(layout.isCompact ? 0 : 1)
                        .allowsHitTesting(!layout.isCompact)
                        .accessibilityHidden(layout.isCompact)
                        .focusedValue(\.calendarWorkspaceHasFocus, true)
                    if let calendarPanel {
                        CalendarUtilityPanel(layout: layout, height: geometry.size.height,
                            title: calendarPanel == .tasks ? "Tasks" : "Assistant",
                            canClose: calendarPanel != .tasks || tasksAllowClosing,
                            backFocused: $compactBackFocused, onBack: closeCalendarPanel, onResize: resizeAssistant) {
                            ZStack {
                                if calendarPanel == .tasks {
                                    GoogleTasksSidebar(model: app.tasks, onClose: closeCalendarPanel,
                                        isActive: app.destination == .calendar,
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
                .opacity(app.destination == .calendar ? 1 : 0)
                .allowsHitTesting(app.destination == .calendar)
                .accessibilityHidden(app.destination != .calendar)
                .zIndex(app.destination == .calendar ? 1 : 0)
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
            .onChange(of: layout.isCompact) { _, compact in
                if compact, app.destination == .calendar, calendarHasFocus == true {
                    compactBackFocused = true
                }
            }
            .task { await app.calendar.start() }
            .onChange(of: app.tasksSidebarRequest, initial: true) { _, request in
                if app.destination == .calendar, request != nil {
                    if calendarPanel != .tasks { toggleCalendarPanel(.tasks) }
                    app.didShowTasks()
                }
            }
            .onChange(of: app.destination, initial: true) { _, destination in
                app.calendar.isVisible = destination == .calendar
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
        preferredAssistantWidth = Double(min(max(width, Tokens.Assistant.sidebarMinWidth), Tokens.Assistant.sidebarMaxWidth))
    }

    private func openAssistant(fullScreen: Bool) {
        calendarPanel = nil
        AssistantWindow.open(using: openWindow, fullScreen: fullScreen)
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
