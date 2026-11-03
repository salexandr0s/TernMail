import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var followUpsWorkspaceHasFocus: Bool?
}

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case mail, calendar, followUps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .followUps: "Waiting for"
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
                    ZStack {
                        CalendarView(model: app.calendar, isActive: app.destination == .calendar && !layout.isCompact,
                            sidebarState: calendarSidebar, onDeactivateFocus: {
                                if layout.isCompact { compactBackFocused = true }
                            })
                            .opacity(app.destination == .calendar ? 1 : 0)
                            .allowsHitTesting(app.destination == .calendar)
                            .accessibilityHidden(app.destination != .calendar)
                            .focusedValue(\.calendarWorkspaceHasFocus, app.destination == .calendar)
                        FollowUpsView(model: app.followUps)
                            .opacity(app.destination == .followUps ? 1 : 0)
                            .allowsHitTesting(app.destination == .followUps)
                            .accessibilityHidden(app.destination != .followUps)
                            .focusedValue(\.followUpsWorkspaceHasFocus, app.destination == .followUps)
                            .background {
                                FollowUpsWorkspacePerformance(model: app.followUps,
                                    isActive: app.destination == .followUps && !layout.isCompact)
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
                            backFocused: $compactBackFocused, onBack: closeCalendarPanel, onResize: resizeAssistant) {
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
                    isFollowUpsActive: app.destination == .followUps) {
                    compactBackFocused = true
                }
            }
            .task { await app.calendar.start() }
            .onChange(of: app.tasksSidebarRequest, initial: true) { _, request in
                if app.destination != .mail, request != nil {
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

private struct CalendarWorkspaceFocusTransfer: View {
    let isCompact: Bool
    let isCalendarActive: Bool
    let isFollowUpsActive: Bool
    let onNeedsBackFocus: () -> Void
    @FocusedValue(\.calendarWorkspaceHasFocus) private var calendarHasFocus
    @FocusedValue(\.followUpsWorkspaceHasFocus) private var followUpsHasFocus

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: isCompact) { _, compact in
                if compact, (isCalendarActive && calendarHasFocus == true)
                    || (isFollowUpsActive && followUpsHasFocus == true) {
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
