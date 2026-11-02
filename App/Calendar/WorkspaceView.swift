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
    @State private var minimumWidth = Tokens.Layout.windowMinWidth
    /// Shared with the mail assistant, so the panel keeps one width across launches.
    @AppStorage(AssistantSidebarLayout.widthKey) private var preferredAssistantWidth = Double(Tokens.Assistant.sidebarWidth)
    let mailbox: MailboxModel

    var body: some View {
        GeometryReader { geometry in
            let showsRail = geometry.size.width >= Tokens.Workspace.railBreakpoint
            HStack(spacing: 0) {
                if showsRail {
                    WorkspaceNavigationRail(section: section) { $0.select(in: app, mailbox: mailbox) }
                }
                workspace
            }
            .environment(\.showsWorkspaceRail, showsRail)
            .environment(\.workspaceWindowWidth, geometry.size.width)
        }
        .onPreferenceChange(WorkspaceMinimumWidth.self) { minimumWidth = $0 }
        .frame(minWidth: minimumWidth, minHeight: Tokens.Layout.windowMinHeight)
    }

    private var section: WorkspaceSection {
        if app.destination == .calendar { return .calendar }
        return mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID ? .attachments : .mail
    }

    private var workspace: some View {
        ZStack {
            MainView(mailbox: mailbox, isActive: app.destination == .mail,
                calendarPanel: calendarPanel,
                onCalendarPanelToggle: { calendarPanel = calendarPanel == $0 ? nil : $0 }, calendarSidebarState: calendarSidebar)
                .opacity(app.destination == .mail ? 1 : 0)
                .allowsHitTesting(app.destination == .mail)
                .accessibilityHidden(app.destination != .mail)
                .zIndex(app.destination == .mail ? 1 : 0)
                .background {
                    MailWorkspacePerformance(mailbox: mailbox, isActive: app.destination == .mail)
                }
            HStack(spacing: 0) {
                CalendarView(model: app.calendar, isActive: app.destination == .calendar, sidebarState: calendarSidebar)
                if let calendarPanel {
                    Rectangle()
                        .fill(Tokens.Surface.border)
                        .frame(width: Tokens.Border.hairline)
                        .overlay {
                            AssistantSidebarResizeHandle(width: CGFloat(preferredAssistantWidth), onResize: resizeAssistant)
                                .frame(width: Tokens.Space.s3)
                                .accessibilityElement()
                                .accessibilityLabel(calendarPanel == .tasks ? "Tasks width" : "Assistant width")
                                .accessibilityValue("\(Int(preferredAssistantWidth)) points")
                                .accessibilityAdjustableAction { direction in
                                    resizeAssistant(CGFloat(preferredAssistantWidth) + (direction == .increment ? Tokens.Space.s4 : -Tokens.Space.s4))
                                }
                        }
                    Group {
                        if calendarPanel == .tasks {
                            GoogleTasksSidebar(model: app.tasks, onClose: { self.calendarPanel = nil },
                                isActive: app.destination == .calendar)
                        } else {
                            AssistantView(model: app.assistant, onOpenSource: app.openAssistantSource,
                                onExpand: { openAssistant(fullScreen: true) },
                                onDetach: { openAssistant(fullScreen: false) },
                                onClose: { self.calendarPanel = nil })
                        }
                    }
                    .frame(width: CGFloat(preferredAssistantWidth))
                }
            }
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
        .task { await app.calendar.start() }
        .onChange(of: app.tasksSidebarRequest, initial: true) { _, request in
            if app.destination == .calendar, request != nil { calendarPanel = .tasks; app.didShowTasks() }
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
